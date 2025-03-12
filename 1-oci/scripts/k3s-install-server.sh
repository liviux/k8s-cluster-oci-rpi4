#!/bin/bash

set -euo pipefail
trap cleanup EXIT

readonly LOG_FILE="/var/log/k3s-install.log"
readonly JOURNAL_MAX_SIZE="100M"
readonly MAX_RETRIES=30
readonly RETRY_INTERVAL=30
readonly HELM_TIMEOUT="5m"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

touch "$LOG_FILE"

log() {
    local readonly level="$1"
    local readonly message="$2"
    local readonly timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$${timestamp} [$${level}] $${message}" | tee -a "$LOG_FILE"
}

cleanup() {
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Installation failed with exit code $exit_code. Check $${LOG_FILE} for details"
    fi
}

retry_command() {
    local -r cmd="$1"
    local -r description="$2"
    
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    log "INFO" "Executing: $description"
    
    for i in $(seq 1 $MAX_RETRIES); do
        if eval "$cmd"; then
            log "INFO" "$description successful"
            return 0
        else
            log "WARN" "$description failed, attempt $i of $MAX_RETRIES"
            sleep $RETRY_INTERVAL
        fi
    done
    
    log "ERROR" "$description failed after $MAX_RETRIES attempts"
    return 1
}

wait_for_resource() {
    local -r namespace="$1"
    local -r resource_type="$2"
    local -r status_pattern="$${3:-Running}"
    local -r description="$${4:-resources}"
    
    log "INFO" "Waiting for $description in namespace $namespace"
    for i in $(seq 1 $MAX_RETRIES); do
        if kubectl get $resource_type -n $namespace | grep "$status_pattern"; then
            log "INFO" "$description are ready"
            return 0
        fi
        log "INFO" "Waiting for $description... attempt $i of $MAX_RETRIES"
        sleep $RETRY_INTERVAL
    done
    
    log "ERROR" "$description did not become ready after $MAX_RETRIES attempts"
    return 1
}

setup_system() {
    log "INFO" "Setting up system requirements"
    
    /usr/sbin/netfilter-persistent flush || true
    systemctl stop netfilter-persistent.service || true
    systemctl mask --now netfilter-persistent.service || true
    
        # Configure system for Cilium direct routing
    log "INFO" "Configuring system for Cilium direct routing"
    cat > /etc/sysctl.d/99-kubernetes-cni.conf <<EOF
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system

    log "INFO" "Updating system packages"
    apt-get update
    apt-get install -y software-properties-common jq
    
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        python3 python3-full python3-venv \
        git curl ca-certificates gnupg apt-transport-https open-iscsi util-linux linux-modules-extra-$(uname -r) linux-image-generic linux-headers-generic

    apt-get clean
    rm -rf /var/lib/apt/lists/*

    log "INFO" "Configuring journald"
    mkdir -p /etc/systemd/journald.conf.d/
    cat > /etc/systemd/journald.conf.d/size.conf <<EOF
[Journal]
SystemMaxUse=$${JOURNAL_MAX_SIZE}
SystemMaxFileSize=$${JOURNAL_MAX_SIZE}
RuntimeMaxUse=$${JOURNAL_MAX_SIZE}
EOF
    systemctl restart systemd-journald
    systemctl enable --now iscsid.service
}  

install_oci_cli() {
    log "INFO" "Installing OCI CLI"
    python3 -m venv /opt/oci-cli-venv
    /opt/oci-cli-venv/bin/pip install --upgrade pip
    /opt/oci-cli-venv/bin/pip install oci-cli
    ln -sf /opt/oci-cli-venv/bin/oci /usr/local/bin/oci
}

determine_instance_role() {
    log "INFO" "Determining instance role in the cluster"
    export OCI_CLI_AUTH=instance_principal
    first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED  | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
    instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')
    
    if [[ "$first_instance" == "$instance_id" ]]; then
        log "INFO" "This instance is the first server - will initialize cluster"
        return 0
    else
        log "INFO" "This instance is not the first server - will join existing cluster"
        return 1
    fi
}

wait_for_api_server() {
    log "INFO" "Waiting for K3s API server"
    for i in $(seq 1 $MAX_RETRIES); do
        if curl --output /dev/null --silent -k https://${k3s_url}:6443; then
            log "INFO" "K3s API server is ready"
            return 0
        fi
        log "INFO" "Waiting for API server... attempt $i of $MAX_RETRIES"
        sleep $RETRY_INTERVAL
    done
    
    log "ERROR" "K3s API server did not become ready after $MAX_RETRIES attempts"
    return 1
}

wait_for_all_nodes_to_join() {
    local expected_node_count=4  
    log "INFO" "Waiting for at least $expected_node_count nodes to join the cluster (even in NotReady state)"
    
    for i in $(seq 1 $MAX_RETRIES); do
        local current_node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        
        if [ "$current_node_count" -ge "$expected_node_count" ]; then
            log "INFO" "All expected nodes have joined the cluster ($current_node_count nodes detected)"
            kubectl get nodes -o wide
            return 0
        fi
        
        log "INFO" "Waiting for all nodes to join... Currently $current_node_count/$expected_node_count nodes joined (attempt $i of $MAX_RETRIES)"
        sleep $RETRY_INTERVAL
    done
    
    log "WARN" "Not all nodes joined within timeout period. Continuing with available nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l)/$expected_node_count"
    kubectl get nodes -o wide
    return 1
}

wait_for_all_nodes_ready() {
    local expected_node_count=4  # Adjust as needed
    log "INFO" "Waiting for all nodes to become Ready and for all Cilium pods to be Ready"

    for i in $(seq 1 $MAX_RETRIES); do
        local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep " Ready " | wc -l)

        # Check for basic node readiness
        if [ "$total_nodes" -ne "$expected_node_count" ] || [ "$ready_nodes" -ne "$expected_node_count" ]; then
            log "INFO" "Waiting for nodes to become Ready... $ready_nodes/$total_nodes nodes are Ready (attempt $i of $MAX_RETRIES)"
            sleep $RETRY_INTERVAL
            continue
        fi

        # Check for Cilium pod readiness.  Gets *all* pods in kube-system,
        # filters for those with the cilium label, and then checks their status.
        local cilium_pods_ready=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | awk '{print $3}' | grep -c "Running")
        local cilium_pods_total=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | wc -l)

        if [ "$cilium_pods_total" -eq 0 ]; then
             log "INFO" "No cilium pods found yet. (attempt $i of $MAX_RETRIES)"
             sleep $RETRY_INTERVAL
             continue
        fi

        if [ "$cilium_pods_ready" -ne "$cilium_pods_total" ]; then
            log "INFO" "Waiting for all Cilium pods to be Ready... $cilium_pods_ready/$cilium_pods_total Cilium pods are Ready (attempt $i of $MAX_RETRIES)"
            kubectl get pods -n kube-system -l k8s-app=cilium -o wide # Show Cilium pod status
            sleep $RETRY_INTERVAL
            continue
        fi

        # If we get here, all nodes are Ready and all Cilium pods are Ready
        log "INFO" "All $total_nodes nodes are Ready, and all $cilium_pods_total Cilium pods are Ready"
        kubectl get nodes -o wide
        kubectl get pods -n kube-system -l k8s-app=cilium -o wide # Show final Cilium pod status
        return 0
    done

    log "ERROR" "Not all nodes became Ready and Cilium pods Ready within timeout period"
    kubectl get nodes -o wide
    kubectl get pods -n kube-system -l k8s-app=cilium -o wide # Show final Cilium pod status
    return 1
}

install_k3s() {
    log "INFO" "Preparing K3s installation"
    
    local k3s_install_params=(
        "--tls-san ${k3s_tls_san}"
        "--disable traefik"
        "--disable local-storage"
        "--disable-kube-proxy"
        "--disable-network-policy"
        "--disable=servicelb"
        "--disable=metrics-server"
        "--flannel-backend none"
        "--write-kubeconfig-mode 644"
    )
    
    %{ if expose_kubeapi }
    k3s_install_params+=("--tls-san ${k3s_tls_san_public}")
    %{ endif }
    
    local INSTALL_PARAMS="$${k3s_install_params[*]}"
    
    %{ if k3s_version == "latest" }
    local K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
    %{ else }
    local K3S_VERSION="${k3s_version}"
    %{ endif }
    
    log "INFO" "Installing K3s version: $K3S_VERSION"
    
    if determine_instance_role; then
        log "INFO" "Initializing K3s cluster"
        retry_command "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --cluster-init $INSTALL_PARAMS" \
                    "K3s cluster initialization"
    else
        log "INFO" "Joining K3s cluster"
        wait_for_api_server
        retry_command "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --server https://${k3s_url}:6443 $INSTALL_PARAMS" \
                    "K3s cluster join"
    fi
}

wait_for_k3s_ready() {
    log "INFO" "Waiting for K3s API to be available"
    for i in $(seq 1 $MAX_RETRIES); do
        if kubectl get --raw "/api" &>/dev/null; then
            log "INFO" "K3s API is ready"
            return 0
        fi
        log "INFO" "Waiting for K3s API... attempt $i of $MAX_RETRIES"
        sleep $RETRY_INTERVAL
    done
    
    log "ERROR" "K3s API did not become ready after $MAX_RETRIES attempts"
    return 1
}

render_traefik2_config() {
    log "INFO" "Generating Traefik configuration"
cat << 'EOF' > "$TRAEFIK_VALUES_FILE"
service:
  enabled: true
  type: NodePort

ports:
  traefik:
    port: 9000
    expose:
      enabled: false
    exposedPort: 9000
    protocol: TCP
  web:
    port: 8000
    expose:
      enabled: true
    exposedPort: 80
    protocol: TCP
    nodePort: ${ingress_controller_http_nodeport}
    proxyProtocol:
      trustedIPs:
        - 0.0.0.0/0
        - 127.0.0.1/32
      insecure: false
  websecure:
    port: 8443
    expose:
      enabled: true
    exposedPort: 443
    protocol: TCP
    nodePort: ${ingress_controller_https_nodeport}
    tls:
      enabled: true
      options: ""
      certResolver: ""
      domains: []
    proxyProtocol:
      trustedIPs:
        - 0.0.0.0/0
        - 127.0.0.1/32
      insecure: false
    middlewares: []
  metrics:
    port: 9100
    expose:
      enabled: false
    exposedPort: 9100
    protocol: TCP
EOF
}

render_staging_issuer() {
    log "INFO" "Generating Let's Encrypt staging issuer configuration"
    STAGING_ISSUER_RESOURCE=$1
cat << 'EOF' > "$STAGING_ISSUER_RESOURCE"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
 name: letsencrypt-staging
 namespace: cert-manager
spec:
 acme:
   server: https://acme-staging-v02.api.letsencrypt.org/directory
   email: ${certmanager_email_address}
   privateKeySecretRef:
     name: letsencrypt-staging
   solvers:
   - http01:
       ingress:
         class: traefik
EOF
}

render_prod_issuer() {
    log "INFO" "Generating Let's Encrypt production issuer configuration"
    PROD_ISSUER_RESOURCE=$1
cat << 'EOF' > "$PROD_ISSUER_RESOURCE"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: cert-manager
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${certmanager_email_address}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
EOF
}

install_components() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    log "INFO" "DEBUG: k3s_url value is: ${k3s_url}"


    log "INFO" "Installing Helm"
    curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /root/get_helm.sh
    retry_command "/root/get_helm.sh --version ${helm_version}" "Helm installation"
    rm -f /root/get_helm.sh
    
    helm repo add longhorn https://charts.longhorn.io || true
    helm repo add traefik https://traefik.github.io/charts || true
    helm repo add jetstack https://charts.jetstack.io || true
    helm repo add argo https://argoproj.github.io/argo-helm || true
    helm repo add cilium https://helm.cilium.io/ || true    
    helm repo update

    log "INFO" "Waiting for all nodes to join the cluster before installing Cilium"
    wait_for_all_nodes_to_join
    log "INFO" "Wait 120 seconds"
    sleep 120

    log "INFO" "Installing Cilium"

    retry_command "helm upgrade --install cilium cilium/cilium \
                --namespace kube-system \
                --set kubeProxyReplacement=true \
                --set kubeProxyReplacementHealthzBindAddr="0.0.0.0:10256" \
                --set cluster.name=${cluster_name} \
                --set k8sServiceHost=${k3s_url} \
                --set k8sServicePort=6443 \
                --set ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16" \
                --set nodeinit.enabled=true \
                --set ipam.mode=kubernetes \
                --set k8s.requireIPv4PodCIDR=true \
                --set tunnelProtocol=geneve \
                --set rollOutCiliumPods=true \
                --set operator.rollOutPods=true \
                --set operator.replicas=3 \
                --set bpf.masquerade=true \
                --set monitor.enabled=true \
                --set hubble.metrics.enabled='{dns,drop,tcp,flow,icmp,http}' \
                --set hubble.relay.enabled=true \
                --set hubble.ui.enabled=true \
                --wait --timeout $HELM_TIMEOUT \
                --version ${cilium_release}" "Cilium installation"

    log "INFO" "Verifying all nodes become Ready after Cilium installation"
    wait_for_all_nodes_ready
    log "INFO" "Wait 120 seconds"
    sleep 120

    log "INFO" "Installing Tetragon"
    retry_command "helm upgrade --install tetragon cilium/tetragon \
                 --namespace kube-system \
                 --wait --timeout $HELM_TIMEOUT \
                 --version ${tetragon_release}" "Tetragon installation"

    log "INFO" "Wait 60 seconds"
    sleep 60

    log "INFO" "Installing Longhorn"
    kubectl create namespace longhorn-system || true
    retry_command "helm upgrade --install longhorn longhorn/longhorn \
                 --namespace longhorn-system \
                 --wait --timeout $HELM_TIMEOUT \
                 --version ${longhorn_release}" "Longhorn installation"
    
    log "INFO" "Installing Traefik"
    kubectl create namespace traefik || true
    TRAEFIK_VALUES_FILE=/root/traefik2_values.yaml
    render_traefik2_config
    retry_command "helm upgrade --install traefik traefik/traefik \
                 --namespace=traefik \
                 --wait --timeout $HELM_TIMEOUT \
                 --version ${traefik_release} \
                 -f $TRAEFIK_VALUES_FILE" "Traefik installation"
    
    log "INFO" "Installing cert-manager"
    kubectl create namespace cert-manager || true
    retry_command "helm upgrade --install cert-manager jetstack/cert-manager \
                 --namespace cert-manager \
                 --wait --timeout $HELM_TIMEOUT \
                 --version ${certmanager_release} \
                 --set installCRDs=true" "cert-manager installation"
    
    render_staging_issuer /root/staging_issuer.yaml
    render_prod_issuer /root/prod_issuer.yaml
        
    log "INFO" "Waiting for cert-manager to be ready"
    wait_for_resource "cert-manager" "pods" "Running" "cert-manager pods"
    
    kubectl apply -f /root/prod_issuer.yaml
    sleep 5
    kubectl apply -f /root/staging_issuer.yaml
    
    log "INFO" "Installing ArgoCD"
    kubectl create namespace argocd || true 
    retry_command "helm upgrade --install argocd argo/argo-cd \
                 --namespace argocd \
                 --wait --timeout $HELM_TIMEOUT \
                 --version ${argocd_release}" "ArgoCD installation"
    
    retry_command "helm upgrade --install argocd-image-updater argo/argocd-image-updater \
                 --namespace argocd \
                 --wait --timeout $HELM_TIMEOUT \
                 --version ${argocd_image_updater_release}" "ArgoCD Image Updater installation"
}

main() {

    log "INFO" "Starting K3s server installation at $(date)"
    
    setup_system
    install_oci_cli
    install_k3s
    wait_for_k3s_ready


    if determine_instance_role; then
        log "INFO" "Waiting for K3s API (first server - using kubectl)"
        wait_for_k3s_ready
        log "INFO" "Setting up cluster components on first server"
        install_components
    else
        log "INFO" "Skipping kubectl wait and component setup on joining server"
    fi

    
    log "INFO" "K3s server installation completed successfully at $(date)"
    log "INFO" "=== K3s Info ==="
    kubectl cluster-info | tee -a "$LOG_FILE"
    log "INFO" "================="
}

main "$@"