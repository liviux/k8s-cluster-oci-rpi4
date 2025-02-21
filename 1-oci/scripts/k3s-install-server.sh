#!/bin/bash

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

wait_lb() {
while [ true ]
do
  curl --output /dev/null --silent -k https://${k3s_url}:6443
  if [[ "$?" -eq 0 ]]; then
    break
  fi
  sleep 5
  echo "wait for LB"
done
}

install_helm() {
  curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /root/get_helm.sh
  /root/get_helm.sh
}

install_and_configure_traefik2() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # Install Helm
  install_helm

  # Add traefik helm repo
  kubectl create ns traefik
  helm repo add traefik https://helm.traefik.io/traefik
  helm repo update

  TRAEFIK_VALUES_FILE=/root/traefik2_values.yaml
  render_traefik2_config
  helm install --namespace=traefik -f $TRAEFIK_VALUES_FILE traefik traefik/traefik
}

render_traefik2_config() {
cat << 'EOF' > "$TRAEFIK_VALUES_FILE"
service:
  enabled: true
  type: NodePort

# Configure ports
ports:
  # The name of this one can't be changed as it is used for the readiness and
  # liveness probes, but you can adjust its config to your liking
  traefik:
    port: 9000
    # Use hostPort if set.
    # hostPort: 9000
    #
    # Use hostIP if set. If not set, Kubernetes will default to 0.0.0.0, which
    # means it's listening on all your interfaces and all your IPs. You may want
    # to set this value if you need traefik to listen on specific interface
    # only.
    # hostIP: 192.168.100.10

    # Override the liveness/readiness port. This is useful to integrate traefik
    # with an external Load Balancer that performs healthchecks.
    # Default: ports.traefik.port
    # healthchecksPort: 9000

    # Override the liveness/readiness scheme. Useful for getting ping to
    # respond on websecure entryPoint.
    # healthchecksScheme: HTTPS

    # Defines whether the port is exposed if service.type is LoadBalancer or
    # NodePort.
    #
    # You SHOULD NOT expose the traefik port on production deployments.
    # If you want to access it from outside of your cluster,
    # use `kubectl port-forward` or create a secure ingress
    expose: false
    # The exposed port for this service
    exposedPort: 9000
    # The port protocol (TCP/UDP)
    protocol: TCP
  web:
    port: 8000
    # hostPort: 8000
    expose: true 
    exposedPort: 80
    # The port protocol (TCP/UDP)
    protocol: TCP
    # Use nodeport if set. This is useful if you have configured Traefik in a
    # LoadBalancer
    nodePort: ${ingress_controller_http_nodeport}
    # Port Redirections
    # Added in 2.2, you can make permanent redirects via entrypoints.
    # https://docs.traefik.io/routing/entrypoints/#redirection
    # redirectTo: websecure
    #
    # Trust forwarded  headers information (X-Forwarded-*).
    # forwardedHeaders:
    #   trustedIPs: []
    #   insecure: false
    #
    # Enable the Proxy Protocol header parsing for the entry point
    proxyProtocol:
      trustedIPs:
        - 0.0.0.0/0
        - 127.0.0.1/32
      insecure: false
  websecure:
    port: 8443
    # hostPort: 8443
    expose: true
    exposedPort: 443
    # The port protocol (TCP/UDP)
    protocol: TCP
    nodePort: ${ingress_controller_https_nodeport}
    # Enable HTTP/3.
    # Requires enabling experimental http3 feature and tls.
    # Note that you cannot have a UDP entrypoint with the same port.
    # http3: true
    # Set TLS at the entrypoint
    # https://doc.traefik.io/traefik/routing/entrypoints/#tls
    tls:
      enabled: true
      # this is the name of a TLSOption definition
      options: ""
      certResolver: ""
      domains: []
      # - main: example.com
      #   sans:
      #     - foo.example.com
      #     - bar.example.com
    #
    # Trust forwarded  headers information (X-Forwarded-*).
    # forwardedHeaders:
    #   trustedIPs: []
    #   insecure: false
    #
    # Enable the Proxy Protocol header parsing for the entry point
    proxyProtocol:
      trustedIPs:
        - 0.0.0.0/0
        - 127.0.0.1/32
      insecure: false
    #
    # One can apply Middlewares on an entrypoint
    # https://doc.traefik.io/traefik/middlewares/overview/
    # https://doc.traefik.io/traefik/routing/entrypoints/#middlewares
    # /!\ It introduces here a link between your static configuration and your dynamic configuration /!\
    # It follows the provider naming convention: https://doc.traefik.io/traefik/providers/overview/#provider-namespace
    # middlewares:
    #   - namespace-name1@kubernetescrd
    #   - namespace-name2@kubernetescrd
    middlewares: []
  metrics:
    # When using hostNetwork, use another port to avoid conflict with node exporter:
    # https://github.com/prometheus/prometheus/wiki/Default-port-allocations
    port: 9100
    # hostPort: 9100
    # Defines whether the port is exposed if service.type is LoadBalancer or
    # NodePort.
    #
    # You may not want to expose the metrics port on production deployments.
    # If you want to access it from outside of your cluster,
    # use `kubectl port-forward` or create a secure ingress
    expose: false
    # The exposed port for this service
    exposedPort: 9100
    # The port protocol (TCP/UDP)
    protocol: TCP
EOF
}

render_staging_issuer(){
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

render_prod_issuer(){
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

# System setup
/usr/sbin/netfilter-persistent stop
/usr/sbin/netfilter-persistent flush

systemctl stop netfilter-persistent.service
systemctl disable netfilter-persistent.service

apt-get update
apt-get install -y software-properties-common jq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 python3-full python3-venv

# Fix virtual environment installation
python3 -m venv /opt/oci-cli-venv
/opt/oci-cli-venv/bin/pip install oci-cli
ln -s /opt/oci-cli-venv/bin/oci /usr/local/bin/oci

# Fix /var/log/journal dir size
echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
systemctl restart systemd-journald

export OCI_CLI_AUTH=instance_principal
first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED  | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

k3s_install_params=("--tls-san ${k3s_tls_san}")

%{ if k3s_subnet != "default_route_table" } 
local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')

k3s_install_params+=("--node-ip $local_ip")
k3s_install_params+=("--advertise-address $local_ip")
k3s_install_params+=("--flannel-iface $flannel_iface")
%{ endif }

%{ if expose_kubeapi }
k3s_install_params+=("--tls-san ${k3s_tls_san_public}")
%{ endif }

INSTALL_PARAMS="$${k3s_install_params[*]}"

%{ if k3s_version == "latest" }
K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
%{ else }
K3S_VERSION="${k3s_version}"
%{ endif }

if [[ "$first_instance" == "$instance_id" ]]; then
  echo "I'm the first yeeee: Cluster init!"
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --cluster-init $INSTALL_PARAMS); do
    echo 'k3s did not install correctly'
    sleep 2
  done
else
  echo ":( Cluster join"
  wait_lb
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --server https://${k3s_url}:6443 $INSTALL_PARAMS); do
    echo 'k3s did not install correctly'
    sleep 2
  done
fi

%{ if is_k3s_server }
until kubectl get pods -A | grep 'Running'; do
  echo 'Waiting for k3s startup'
  sleep 5
done

# Longhorn installation
if [[ "$first_instance" == "$instance_id" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
  systemctl enable --now iscsid.service

  install_helm
  helm repo add longhorn https://charts.longhorn.io
  helm repo update
  helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --version ${longhorn_release}
fi

# Traefik installation
install_and_configure_traefik2

# Cert-manager installation
if [[ "$first_instance" == "$instance_id" ]]; then
  install_helm
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  kubectl create namespace cert-manager
  helm install \
    cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version ${certmanager_release} \
    --set installCRDs=true

  render_staging_issuer /root/staging_issuer.yaml
  render_prod_issuer /root/prod_issuer.yaml

  # Wait cert-manager to be ready
  until kubectl get pods -n cert-manager | grep 'Running'; do
    echo 'Waiting for cert-manager to be ready'
    sleep 15
  done

  kubectl create -f /root/prod_issuer.yaml
  kubectl create -f /root/staging_issuer.yaml
fi

# ArgoCD installation
if [[ "$first_instance" == "$instance_id" ]]; then
  install_helm
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  kubectl create namespace argocd
  helm install argocd argo/argo-cd --namespace argocd --version ${argocd_release}
  helm install argocd-image-updater argo/argocd-image-updater --namespace argocd --version ${argocd_image_updater_release}
fi
%{ endif }
