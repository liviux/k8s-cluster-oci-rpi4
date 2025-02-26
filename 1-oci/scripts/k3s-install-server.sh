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

  install_helm

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

ports:
  traefik:
    port: 9000
    expose: false
    exposedPort: 9000
    protocol: TCP
  web:
    port: 8000
    expose: true 
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
    expose: true
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
    expose: false
    exposedPort: 9100
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

/usr/sbin/netfilter-persistent stop
/usr/sbin/netfilter-persistent flush

systemctl stop netfilter-persistent.service
systemctl disable netfilter-persistent.service

apt-get update
apt-get install -y software-properties-common jq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 python3-full python3-venv

python3 -m venv /opt/oci-cli-venv
/opt/oci-cli-venv/bin/pip install oci-cli
ln -s /opt/oci-cli-venv/bin/oci /usr/local/bin/oci

echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
systemctl restart systemd-journald

export OCI_CLI_AUTH=instance_principal
first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED  | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

k3s_install_params=("--tls-san ${k3s_tls_san}")

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

if [[ "$first_instance" == "$instance_id" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
  systemctl enable --now iscsid.service

  install_helm
  helm repo add longhorn https://charts.longhorn.io
  helm repo update
  helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --version ${longhorn_release}
fi

install_and_configure_traefik2

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

  until kubectl get pods -n cert-manager | grep 'Running'; do
    echo 'Waiting for cert-manager to be ready'
    sleep 30
  done

  kubectl apply -f /root/prod_issuer.yaml
  sleep 5
  kubectl apply -f /root/staging_issuer.yaml
fi

if [[ "$first_instance" == "$instance_id" ]]; then
  install_helm
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  kubectl create namespace argocd
  helm install argocd argo/argo-cd --namespace argocd --version ${argocd_release}
  helm install argocd-image-updater argo/argocd-image-updater --namespace argocd --version ${argocd_image_updater_release}
fi
%{ endif }
