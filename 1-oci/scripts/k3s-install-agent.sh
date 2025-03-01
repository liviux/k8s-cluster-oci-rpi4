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

    /usr/sbin/netfilter-persistent flush || true
    systemctl stop netfilter-persistent.service || true
    systemctl disable netfilter-persistent.service || true

    apt-get update
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
       log "ERROR" "apt-get upgrade failed: $(DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1)"
       exit 1
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        apt-utils software-properties-common jq python3 python3-full \
        python3-venv open-iscsi curl util-linux; then

      log "ERROR" "apt-get install failed: $(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apt-utils software-properties-common jq python3 open-iscsi curl util-linux 2>&1)"
      exit 1
    fi
    
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    cat > /etc/systemd/journald.conf <<EOF
SystemMaxUse=$${JOURNAL_MAX_SIZE}
SystemMaxFileSize=$${JOURNAL_MAX_SIZE}
EOF
    systemctl restart systemd-journald

    systemctl enable --now iscsid.service
}

wait_for_api_server() {
    log "INFO" "Waiting for K3s API server"
    until curl --output /dev/null --silent -k https://${k3s_url}:6443; do
        log "INFO" "API server not yet available, waiting 5 seconds..."
        sleep 5
    done
    log "INFO" "K3s API server is responsive."
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

main() {
    log "INFO" "Starting K3s agent installation"
    setup_system
    wait_for_api_server
    install_k3s
    log "INFO" "K3s agent installation completed successfully"
}

main "$@"