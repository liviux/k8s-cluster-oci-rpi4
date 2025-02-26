#!/bin/bash

set -euo pipefail
trap cleanup EXIT

readonly LOG_FILE="/var/log/k3s-install.log"
readonly JOURNAL_MAX_SIZE="100M"

log() {
    local readonly level="$1"
    local readonly message="$2"
    local readonly timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$${timestamp} [$${level}] $${message}" | tee -a "$LOG_FILE"
}

cleanup() {
    if [ $? -ne 0 ]; then
        log "ERROR" "Installation failed. Check $${LOG_FILE} for details"
    fi
}

setup_system() {
    log "INFO" "Setting up system requirements"
    
    systemctl stop netfilter-persistent.service
    systemctl disable netfilter-persistent.service
    /usr/sbin/netfilter-persistent flush
    
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    apt-get install -y software-properties-common jq
    
    cat > /etc/systemd/journald.conf <<EOF
SystemMaxUse=$${JOURNAL_MAX_SIZE}
SystemMaxFileSize=$${JOURNAL_MAX_SIZE}
EOF
    systemctl restart systemd-journald
}

install_oci_cli() {
    log "INFO" "Installing OCI CLI"
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        python3 python3-full nginx python3-venv
        
    python3 -m venv /opt/oci-cli-venv
    /opt/oci-cli-venv/bin/pip install oci-cli
    ln -sf /opt/oci-cli-venv/bin/oci /usr/local/bin/oci
}

wait_for_api_server() {
    log "INFO" "Waiting for K3s API server"
    until curl --output /dev/null --silent -k https://${k3s_url}:6443; do
        log "INFO" "Waiting for API server..."
        sleep 5
    done
}

install_k3s() {
    local k3s_version
    
    %{ if k3s_version == "latest" }
    k3s_version=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
    %{ else }
    k3s_version="${k3s_version}"
    %{ endif }
    
    log "INFO" "Installing K3s version: $k3s_version"
    
    until (curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION=$k3s_version \
        K3S_TOKEN=${k3s_token} \
        K3S_URL=https://${k3s_url}:6443 \
        sh -s - ); do
        log "WARN" "K3s installation failed, retrying..."
        sleep 2
    done
}

setup_longhorn() {
    log "INFO" "Setting up Longhorn requirements"
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        open-iscsi curl util-linux
    systemctl enable --now iscsid.service
}

main() {
    log "INFO" "Starting K3s agent installation"
    setup_system
    install_oci_cli
    wait_for_api_server
    install_k3s
    setup_longhorn
    log "INFO" "K3s agent installation completed successfully"
}

main "$@"