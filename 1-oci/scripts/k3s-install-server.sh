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

setup_system() {
    log "INFO" "Setting up system requirements"
    
    /usr/sbin/netfilter-persistent flush || true
    systemctl stop netfilter-persistent.service || true
    systemctl mask --now netfilter-persistent.service || true
    
    log "INFO" "Updating system packages"
    apt-get update
    apt-get install -y software-properties-common jq
    
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        python3 python3-full python3-venv \
        git curl ca-certificates gnupg apt-transport-https open-iscsi util-linux

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

install_k3s() {
    log "INFO" "Preparing K3s installation"
    
    local k3s_install_params=("--tls-san ${k3s_tls_san}" "--disable traefik" "--disable local-storage" "--write-kubeconfig-mode 644")
    
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

install_components() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    
    log "INFO" "Installing Helm"
    curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /root/get_helm.sh
    retry_command "/root/get_helm.sh --version ${helm_version}" "Helm installation"
    rm -f /root/get_helm.sh
    
    helm repo add longhorn https://charts.longhorn.io || true
    helm repo add traefik https://traefik.github.io/charts || true
    helm repo add jetstack https://charts.jetstack.io || true
    helm repo add argo https://argoproj.github.io/argo-helm || true
    helm repo update

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

check_prerequisites() {
    log "INFO" "Checking system prerequisites"
    
    local cpu_count=$(grep -c processor /proc/cpuinfo)
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    local disk_free=$(df -m / | awk 'NR==2 {print $4}')
    
    log "INFO" "System resources: $cpu_count CPUs, $mem_total MB memory, $disk_free MB disk space"
    
    if [ "$mem_total" -lt 1800 ]; then
        log "WARN" "Less than 2GB of memory available. K3s may be unstable."
    fi
    
    if [ "$disk_free" -lt 10240 ]; then
        log "WARN" "Less than 10GB of disk space available. Consider adding more storage."
    fi
    
    return 0
}

wait_for_k3s_ready() {
    log "INFO" "Waiting for K3s pods to be running"
    for i in $(seq 1 $MAX_RETRIES); do
        if kubectl get pods -A | grep -q 'Running'; then
            log "INFO" "K3s is ready"
            return 0
        fi
        log "INFO" "Waiting for K3s startup... attempt $i of $MAX_RETRIES"
        sleep $RETRY_INTERVAL
    done
    
    log "ERROR" "K3s did not become ready after $MAX_RETRIES attempts"
    return 1
}

main() {
    log "INFO" "Starting K3s server installation at $(date)"
    
    check_prerequisites
    setup_system
    install_oci_cli
    install_k3s
    wait_for_k3s_ready
    
    if determine_instance_role; then
        log "INFO" "Setting up cluster components on first server"
        install_components
    else
        log "INFO" "Skipping component setup as this is a joining server"
    fi
    
    log "INFO" "K3s server installation completed successfully at $(date)"
    log "INFO" "=== K3s Info ==="
    kubectl cluster-info | tee -a "$LOG_FILE"
    log "INFO" "================="
}

main "$@"