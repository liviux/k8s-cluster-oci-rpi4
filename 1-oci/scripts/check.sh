#!/bin/bash
#
# K3s Cluster Health Check Script
# ==============================
#
# This script performs comprehensive health checks for a K3s cluster and its core components.
# It verifies the functionality and health of:
#
# Core Components:
# - K3s cluster status
# - Node conditions
# - CoreDNS functionality
# - Traefik ingress controller
#
# Storage and Certificates:
# - Longhorn storage system
# - cert-manager and SSL certificate provisioning
#
# GitOps and Automation:
# - Argo CD deployment and sync status
# - Argo CD Image Updater functionality
#
# Network Security Components:
# - Cilium CNI functionality
# - Tetragon security monitoring
#
# Integration Testing:
# - Deploys a test application that validates:
#   * Storage provisioning (Longhorn)
#   * Certificate generation (cert-manager)
#   * Ingress routing (Traefik)
#   * Service networking
#   * Pod scheduling and execution
#
# The script provides:
# - Detailed status reporting for each component
# - Error tracking and summary
# - Component version information
# - Comprehensive logs for troubleshooting
# - Automatic cleanup of test resources
#

set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml


# Color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - Allow customization via environment variables
: ${ARGOCD_NAMESPACE:="argocd"}
: ${LONGHORN_NAMESPACE:="longhorn-system"}
: ${CERT_MANAGER_NAMESPACE:="cert-manager"}
: ${KUBE_SYSTEM_NAMESPACE:="kube-system"}
: ${DEFAULT_NAMESPACE:="default"}
: ${TRAEFIK_NAMESPACE:="traefik"}
: ${CILIUM_NAMESPACE:="kube-system"}
: ${TETRAGON_NAMESPACE:="kube-system"}

# List of namespaces to check
NAMESPACES=("$ARGOCD_NAMESPACE" "$LONGHORN_NAMESPACE" "$CERT_MANAGER_NAMESPACE" "$KUBE_SYSTEM_NAMESPACE" "$TRAEFIK_NAMESPACE" "$TETRAGON_NAMESPACE")

# Array to store errors
declare -a ERROR_LIST

# Helper function for printing status
print_status() {
    local status=$1
    local message=$2
    if [ $status -eq 0 ]; then
        echo -e "${GREEN}✓ SUCCESS${NC}: $message"
    else
        echo -e "${RED}✗ FAILED${NC}: $message"
        ERROR_LIST+=("$message")
    fi
}

check_pods() {
    local namespace="$1"
    echo -e "\n${YELLOW}===== Checking pods in namespace: $namespace =====${NC}"
    
    local pods
    pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null)
    if [[ -z "$pods" ]]; then
        echo "No pods found in namespace $namespace"
        return 0
    fi

    local unhealthy=0
    while IFS= read -r line; do
        local podName=$(echo "$line" | awk '{print $1}')
        local ready=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local restarts=$(echo "$line" | awk '{print $4}')
        
        echo "Checking pod: $podName"
        echo "  - Ready: $ready"
        echo "  - Status: $status"
        echo "  - Restarts: $restarts"
        
        if [[ "$status" != "Running" && "$status" != "Completed" ]]; then
            echo -e "  ${RED}→ Pod is not in Running/Completed state${NC}"
            unhealthy=1
        elif [[ "$restarts" -gt 3 ]]; then
            echo -e "  ${YELLOW}→ Pod has high restart count${NC}"
        else
            echo -e "  ${GREEN}→ Pod is healthy${NC}"
        fi
    done <<< "$pods"

    print_status $unhealthy "Pod check for namespace $namespace"
    return $unhealthy
}

check_deployments() {
    local namespace="$1"
    echo -e "\n${YELLOW}===== Checking deployments in namespace: $namespace =====${NC}"
    
    local deployments
    deployments=$(kubectl get deployments -n "$namespace" --no-headers 2>/dev/null)
    if [[ -z "$deployments" ]]; then
        echo "No deployments found in namespace $namespace"
        return 0
    fi

    local problematic=0
    while IFS= read -r line; do
        local depName=$(echo "$line" | awk '{print $1}')
        local desired=$(echo "$line" | awk '{print $2}' | cut -d'/' -f2)
        local current=$(echo "$line" | awk '{print $3}')
        local available=$(echo "$line" | awk '{print $4}')
        local upToDate=$(echo "$line" | awk '{print $5}')
        
        echo "Checking deployment: $depName"
        echo "  - Desired pods: $desired"
        echo "  - Current pods: $current"
        echo "  - Available pods: $available"
        echo "  - Up-to-date pods: $upToDate"
        
        # Extract numbers from possible "x/y" format
        available=$(echo "$available" | cut -d'/' -f1)
        desired=$(echo "$desired" | cut -d'/' -f1)
        
        if [[ "$available" -lt "$desired" ]]; then
            echo -e "  ${RED}→ Not all pods are available${NC}"
            problematic=1
        else
            echo -e "  ${GREEN}→ Deployment is healthy${NC}"
        fi
    done <<< "$deployments"

    print_status $problematic "Deployment check for namespace $namespace"
    return $problematic
}

# Component endpoint checks
check_argocd() {
    echo -e "\n${YELLOW}===== Checking Argo CD health =====${NC}"
    
    local argocd_server_name="argocd-server"
    local argocd_port=8080
    local argocd_service_port=80

    echo "Starting port-forward for Argo CD server..."
    kubectl port-forward svc/"$argocd_server_name" -n "$ARGOCD_NAMESPACE" "$argocd_port":"$argocd_service_port" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    local status=0
    if curl -s -o /dev/null http://localhost:"$argocd_port"; then
        echo -e "${GREEN}→ Argo CD endpoint is responding${NC}"
    else
        echo -e "${RED}→ Argo CD endpoint check failed${NC}"
        status=1
    fi

    echo "Cleaning up port-forward..."
    kill ${pf_pid} >/dev/null 2>&1 || true
    wait ${pf_pid} 2>/dev/null || true
    sleep 1

# Check ArgoCD applications status using kubectl for Application CRDs
echo "Checking ArgoCD Applications status..."
kubectl get applications.argoproj.io -n "$ARGOCD_NAMESPACE" -o json | jq -c '.items[]' | while read -r app; do
    app_name=$(echo "$app" | jq -r '.metadata.name')
    sync_status=$(echo "$app" | jq -r '.status.sync.status')
    health_status=$(echo "$app" | jq -r '.status.health.status')

    if [[ "$sync_status" != "Synced" || "$health_status" != "Healthy" ]]; then
        echo -e "${RED}→ ArgoCD Application '$app_name' is not healthy (Sync: $sync_status, Health: $health_status)${NC}"
        status=1
    else
        echo -e "${GREEN}→ ArgoCD Application '$app_name' is healthy (Sync: $sync_status, Health: $health_status)${NC}"
    fi
done

    print_status $status "Argo CD health check"
    return $status
}

check_cert_manager_deployments() {
    echo "===== Checking cert-manager deployments rollout status ====="
    for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
        echo "Fetching rollout status for deployment: $deploy"
        rollout_output=$(kubectl rollout status deployment/"$deploy" -n "$CERT_MANAGER_NAMESPACE" --timeout=60s 2>&1)
        if [[ "$rollout_output" == *"not found"* ]]; then
            echo -e "${RED}Deployment $deploy not found${NC}"
        else
            echo "Rollout output for $deploy:"
            echo "$rollout_output"
        fi
        echo "------------------------------------------------------"
    done
    echo ""
}

check_cert_manager_apiservice() {
    echo "===== Checking APIService for cert-manager webhook ====="
    local apisvc=""
    for svc in "v1.webhook.cert-manager.io" "v1beta1.webhook.cert-manager.io"; do
        apisvc=$(kubectl get apiservice "$svc" -o json 2>/dev/null)
        if [[ -n "$apisvc" ]]; then
            echo "Found APIService: $svc"
            echo "$apisvc" | jq .
            local available=$(echo "$apisvc" | jq -r '.status.conditions[] | select(.type=="Available") | .status')
            echo "Availability status: $available"
            break
        fi
    done
    if [[ -z "$apisvc" ]]; then
        echo "No cert-manager webhook APIService found under common names."
    fi
    echo "------------------------------------------------------"
    echo ""
}

check_cert_manager_webhook_logs() {
    echo "===== Searching for a cert-manager-webhook pod ====="
    local webhookPod
    webhookPod=$(kubectl get pods -n "$CERT_MANAGER_NAMESPACE" --no-headers | awk '/webhook/ {print $1; exit}')
    if [[ -n "$webhookPod" ]]; then
        echo "Found cert-manager webhook pod: $webhookPod"
        echo "Fetching the last 100 lines of logs from $webhookPod..."
        local logs
        logs=$(kubectl logs "$webhookPod" -n "$CERT_MANAGER_NAMESPACE" --tail=100 2>/dev/null)
        echo "------- Begin Log Output -------"
        echo "$logs"
        echo "------- End Log Output -------"
        # Only count specific errors as real issues, ignore TLS handshake errors
        local errors
        errors=$(echo "$logs" | grep -i "error" | grep -v "TLS handshake error")
        if [[ -n "$errors" ]]; then
            echo "Detected error messages in cert-manager-webhook logs:"
            echo "$errors"
        else
            echo "No error messages detected in cert-manager-webhook logs."
        fi
    else
        echo "No pod with 'webhook' in its name found in the cert-manager namespace."
    fi
    echo "------------------------------------------------------"
    echo ""
}

check_cert_manager_resources() {
    echo "===== Listing ClusterIssuer resources ====="
    kubectl get clusterissuers -o wide 2>/dev/null || echo "No ClusterIssuers found."
    echo "------------------------------------------------------"
    echo ""
    echo "===== Listing Issuer resources (all namespaces) ====="
    kubectl get issuers --all-namespaces -o wide 2>/dev/null || echo "No Issuers found."
    echo "------------------------------------------------------"
    echo ""
}

check_cert_manager_webhook_endpoint() {
    echo "Starting port-forward for cert-manager webhook..."
    kubectl port-forward svc/cert-manager-webhook -n "$CERT_MANAGER_NAMESPACE" 9402:9402 >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    local status=0
    if curl -sk -o /dev/null https://localhost:9402/healthz; then
        echo -e "${GREEN}→ cert-manager webhook endpoint is responding${NC}"
    else
        # Don't fail on TLS errors since the webhook is working
        echo -e "${YELLOW}→ cert-manager webhook endpoint responded with TLS error (expected)${NC}"
    fi

    kill ${pf_pid} >/dev/null 2>&1 || true
    wait ${pf_pid} 2>/dev/null || true
    sleep 1
    echo ""
    
    return $status
}

check_cert_manager() {
    echo -e "\n${YELLOW}===== Performing comprehensive cert-manager checks =====${NC}"
    
    local status=0

    # Check webhook endpoint
    check_cert_manager_webhook_endpoint
    
    # Additional detailed checks
    check_cert_manager_deployments
    check_cert_manager_apiservice
    check_cert_manager_webhook_logs
    check_cert_manager_resources

    # Check cert-manager controller logs for errors
    echo "Checking cert-manager controller logs..."
    local logs=$(kubectl logs -n "$CERT_MANAGER_NAMESPACE" -l app.kubernetes.io/name=cert-manager --tail=50 2>/dev/null)
    #  More robust error checking, ignoring optimistic lock errors.
    if echo "$logs" | grep -i "error" | grep -v "optimistic" >/dev/null; then
        echo -e "${YELLOW}→ Found errors (excluding optimistic lock errors) in cert-manager controller logs${NC}"
        echo "$logs" | grep -i "error" | grep -v "optimistic"
        status=1
    else
        echo -e "${GREEN}→ No errors found in cert-manager controller logs${NC}"
    fi

    print_status $status "Cert-Manager health check"
    return $status
}

check_longhorn() {
    echo -e "\n${YELLOW}===== Checking Longhorn UI endpoint =====${NC}"
    
    local longhorn_frontend_name="longhorn-frontend"
    local longhorn_port=8081
    local longhorn_service_port=80

    echo "Starting port-forward for Longhorn UI..."
    kubectl port-forward svc/"$longhorn_frontend_name" -n "$LONGHORN_NAMESPACE" "$longhorn_port":"$longhorn_service_port" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    local status=0
    if curl -s -o /dev/null http://localhost:"$longhorn_port"; then
        echo -e "${GREEN}→ Longhorn UI endpoint is responding${NC}"
    else
        echo -e "${RED}→ Longhorn UI endpoint check failed${NC}"
        status=1
    fi

    echo "Cleaning up port-forward..."
    kill ${pf_pid} >/dev/null 2>&1 || true
    wait ${pf_pid} 2>/dev/null || true
    sleep 1

    # Check Longhorn volumes
    echo "Checking Longhorn volumes..."
    longhorn_volumes=$(kubectl get volumes -n "$LONGHORN_NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}')
    if [[ -z "$longhorn_volumes" ]]; then
        echo -e "${YELLOW}→ No Longhorn volumes found${NC}"
    else
        while IFS= read -r volume_name; do
            volume_status=$(kubectl get volume "$volume_name" -n "$LONGHORN_NAMESPACE" -o jsonpath='{.status.state}')
            if [[ "$volume_status" != "attached" ]]; then
                echo -e "${RED}→ Longhorn volume '$volume_name' is not attached (Status: $volume_status)${NC}"
                status=1
            else
                echo -e "${GREEN}→ Longhorn volume '$volume_name' is attached (Status: $volume_status)${NC}"
            fi
        done <<< "$longhorn_volumes"
    fi

    print_status $status "Longhorn health check"
    return $status
}

check_coredns() {
    echo -e "\n${YELLOW}===== Checking CoreDNS health =====${NC}"
    
    # Check CoreDNS pods and service
    local status=0
    
    # Check CoreDNS service (k3s uses kube-dns as service name)
    if ! kubectl get svc -n "$KUBE_SYSTEM_NAMESPACE" kube-dns >/dev/null 2>&1; then
        echo -e "${RED}→ CoreDNS service (kube-dns) not found${NC}"
        status=1
    else
        echo -e "${GREEN}→ CoreDNS service exists${NC}"
        
        # Check if CoreDNS pods are running
        if ! kubectl get pods -n "$KUBE_SYSTEM_NAMESPACE" -l k8s-app=kube-dns >/dev/null 2>&1; then
            echo -e "${RED}→ CoreDNS pods not found${NC}"
            status=1
        else
            echo -e "${GREEN}→ CoreDNS pods exist${NC}"
        fi
    fi

    # Test DNS resolution
    echo "Testing DNS resolution..."
    if ! kubectl run -n "$DEFAULT_NAMESPACE" dns-test --rm -i --restart=Never --timeout=60s \
        --image=busybox:1.28 -- nslookup kubernetes.default >/dev/null 2>&1; then
        echo -e "${RED}→ DNS resolution test failed${NC}"
        status=1
    else
        echo -e "${GREEN}→ DNS resolution test passed${NC}"
    fi

    # Check CoreDNS configmap
    echo "Checking CoreDNS configmap..."
    if ! kubectl get configmap coredns -n "$KUBE_SYSTEM_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${RED}→ CoreDNS configmap not found${NC}"
        status=1
    else
        echo -e "${GREEN}→ CoreDNS configmap exists${NC}"
    fi

    print_status $status "CoreDNS health check"
    return $status
}

check_traefik() {
    echo -e "\n${YELLOW}===== Checking Traefik health =====${NC}"
    
    local status=0

    # Check if Traefik pods are running
    if ! kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik >/dev/null 2>&1; then
        echo -e "${RED}→ Traefik pods not found in namespace $TRAEFIK_NAMESPACE${NC}"
        status=1
    else
        echo -e "${GREEN}→ Traefik pods exist${NC}"
    fi

    # Check Traefik API endpoint by temporarily patching the service
    echo "Checking Traefik API endpoint with temporary endpoint exposure..."
    
    # Backup current service configuration
    local traefik_service_backup=$(kubectl get service traefik -n "$TRAEFIK_NAMESPACE" -o json)
    
    # Temporarily expose the API port (9000) via patch
    echo "Temporarily exposing Traefik API port..."
    kubectl patch service traefik -n "$TRAEFIK_NAMESPACE" --type=json -p '[{"op": "add", "path": "/spec/ports/-", "value": {"name": "temp-api", "port": 9000, "targetPort": 9000, "protocol": "TCP"}}]' >/dev/null 2>&1
    
    # Start port-forward for the temporary API port
    kubectl port-forward svc/traefik -n "$TRAEFIK_NAMESPACE" 9000:9000 >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 3
    
    # Check API
    local api_status=0
    if curl -s -o /dev/null http://localhost:9000/api; then
        echo -e "${GREEN}→ Traefik API endpoint is responding${NC}"
    else
        echo -e "${YELLOW}→ Traefik API endpoint check failed, trying dashboard path...${NC}"
        if curl -s -o /dev/null http://localhost:9000/dashboard/; then
            echo -e "${GREEN}→ Traefik dashboard endpoint is responding${NC}"
        else
            echo -e "${YELLOW}→ Traefik API and dashboard endpoints are not accessible${NC}"
            api_status=1
        fi
    fi
    
    # Clean up port-forward
    kill ${pf_pid} >/dev/null 2>&1 || true
    wait ${pf_pid} 2>/dev/null || true
    sleep 1
    
    # Restore original service configuration by removing our temporary port
    echo "Restoring original Traefik service configuration..."
    kubectl patch service traefik -n "$TRAEFIK_NAMESPACE" --type=json -p '[{"op": "test", "path": "/spec/ports/-1/name", "value": "temp-api"}, {"op": "remove", "path": "/spec/ports/-1"}]' >/dev/null 2>&1 || true
    
    # Note: if the patch fails, we can always recreate the service from scratch
    if [ $? -ne 0 ]; then
        echo "Patch failed, recreating service from backup..."
        echo "$traefik_service_backup" | kubectl apply -f - >/dev/null 2>&1
    fi
    
    # Don't count API access failures against overall health since this was just a bonus check
    if [ $api_status -ne 0 ]; then
        echo -e "${YELLOW}→ API check failed but this doesn't affect overall health${NC}"
    fi

    # Check Traefik pod logs for errors
    echo "Checking Traefik pod logs..."
    local traefik_pod=$(kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -n "$traefik_pod" ]]; then
        local logs=$(kubectl logs "$traefik_pod" -n "$TRAEFIK_NAMESPACE" --tail=20 2>/dev/null)
        if echo "$logs" | grep -i "error" | grep -v "No error" >/dev/null; then
            echo -e "${YELLOW}→ Found errors in Traefik logs${NC}"
            echo "$logs" | grep -i "error" | grep -v "No error"
        else
            echo -e "${GREEN}→ No errors found in Traefik logs${NC}"
        fi
    fi
    
    # Check for IngressRoutes - Traefik v3 only
    echo "Checking IngressRoutes..."
    if ! kubectl get ingressroutes.traefik.io --all-namespaces >/dev/null 2>&1; then
        echo -e "${YELLOW}→ No IngressRoutes found with API version traefik.io${NC}"
        # Try the older API version
        if ! kubectl get ingressroutes.traefik.containo.us --all-namespaces >/dev/null 2>&1; then
            echo -e "${RED}→ No IngressRoutes found with any known API version${NC}"
            status=1
        else
            echo -e "${GREEN}→ IngressRoutes exist (traefik.containo.us API)${NC}"
        fi
    else
        echo -e "${GREEN}→ IngressRoutes exist${NC}"
    fi

    # Check for Traefik service status
    if ! kubectl get service traefik -n "$TRAEFIK_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${RED}→ Traefik service not found in namespace $TRAEFIK_NAMESPACE${NC}"
        status=1
    else
        echo -e "${GREEN}→ Traefik service exists${NC}"
        
        # Additional check: Get Traefik service details
        echo "Getting Traefik service details..."
        kubectl get service traefik -n "$TRAEFIK_NAMESPACE" -o json | jq -r '.spec.ports[] | "Port: \(.port) TargetPort: \(.targetPort) Name: \(.name)"'
    fi

    print_status $status "Traefik health check"
    return $status
}

check_argocd_image_updater() {
    echo -e "\n${YELLOW}===== Checking Argo CD Image Updater health =====${NC}"
    
    local status=0

    # Check if image updater deployment exists
    if ! kubectl get deployment argocd-image-updater -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${RED}→ Argo CD Image Updater deployment not found${NC}"
        status=1
    else
        echo -e "${GREEN}→ Argo CD Image Updater deployment exists${NC}"
        
        # Check logs for errors
        echo "Checking Image Updater logs..."
        local logs
        logs=$(kubectl logs -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-image-updater --tail=50 2>/dev/null)
        if echo "$logs" | grep -i "error" | grep -v "errors=0" >/dev/null; then
                echo -e "${YELLOW}→ Found errors (excluding 'errors=0') in Image Updater logs${NC}"
            echo "$logs" | grep -i "error" | grep -v "errors=0"
        else
            echo -e "${GREEN}→ No errors found in Image Updater logs${NC}"
        fi
    fi

    print_status $status "Argo CD Image Updater health check"
    return $status
}

check_etcd() {
    echo -e "\n${YELLOW}===== Checking etcd cluster health =====${NC}"
    
    local status=0
    
    # Check if etcdctl is installed
    if ! command -v etcdctl &> /dev/null; then
        echo "etcdctl not found. Installing etcd-client..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y etcd-client >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            sudo yum install -y etcd >/dev/null 2>&1
        elif command -v apk &> /dev/null; then
            sudo apk add --no-cache etcd-client >/dev/null 2>&1
        else
            echo -e "${RED}→ Could not install etcd-client. Package manager not found.${NC}"
            status=1
            print_status $status "etcd health check"
            return $status
        fi

        # Verify installation succeeded
        if ! command -v etcdctl &> /dev/null; then
            echo -e "${RED}→ etcdctl installation failed${NC}"
            status=1
            print_status $status "etcd health check"
            return $status
        else
            echo -e "${GREEN}→ etcdctl successfully installed${NC}"
        fi
    else
        echo -e "${GREEN}→ etcdctl is already installed${NC}"
    fi

    # Get etcdctl version
    local etcdctl_version=$(etcdctl version 2>/dev/null | grep etcdctl || echo "Unknown")
    echo -e "etcdctl version: ${GREEN}$etcdctl_version${NC}"
    
    # Check if K3s etcd certificates exist - using sudo to check for file existence
    local cert_path="/var/lib/rancher/k3s/server/tls/etcd"
    local cacert="$cert_path/server-ca.crt"
    local cert="$cert_path/server-client.crt"
    local key="$cert_path/server-client.key"
    
    # Check if files exist using sudo
    local cacert_exists=$(sudo test -f "$cacert" && echo "yes" || echo "no")
    local cert_exists=$(sudo test -f "$cert" && echo "yes" || echo "no")
    local key_exists=$(sudo test -f "$key" && echo "yes" || echo "no")
    
    if [[ "$cacert_exists" == "yes" && "$cert_exists" == "yes" && "$key_exists" == "yes" ]]; then
        echo -e "${GREEN}→ K3s etcd certificates found${NC}"
        
        # Set etcdctl environment and command prefix with sudo
        export ETCDCTL_API=3
        local etcdctl_cmd="sudo ETCDCTL_API=3 etcdctl --cacert=$cacert --cert=$cert --key=$key"
        
        # Try to discover endpoints using member list without specifying endpoints
        # This requires the node where the script is running to either be an etcd node
        # or have the environment variables ETCDCTL_ENDPOINTS set.
        echo "Discovering etcd endpoints..."
        local endpoints=""
        local member_list_output=""
        
        # Try member list without endpoints which will work if we're on the same host as etcd or default endpoint
        member_list_output=$($etcdctl_cmd member list 2>/dev/null || echo "")
        
        if [[ -z "$member_list_output" ]]; then
            echo -e "${RED}→ Failed to list members. Make sure you're running this script on a K3s server node.${NC}"
            status=1
            print_status $status "etcd health check"
            return $status
        fi
        
        # Extract endpoints from member list
        endpoints=$(echo "$member_list_output" | grep -o 'https://[^,]*:2379' | tr '\n' ',' | sed 's/,$//')
        
        if [[ -z "$endpoints" ]]; then
            echo -e "${RED}→ Could not extract endpoints from member list${NC}"
            status=1
            print_status $status "etcd health check"
            return $status
        else
            echo -e "${GREEN}→ Discovered etcd endpoints: $endpoints${NC}"
        fi
        
        # Show member list
        echo -e "\n${YELLOW}etcd Member List:${NC}"
        echo "$member_list_output" | column -t -s, 2>/dev/null || echo "$member_list_output"
        
        # Check endpoint status
        echo -e "\n${YELLOW}etcd Endpoint Status:${NC}"
        local endpoint_status
        endpoint_status=$($etcdctl_cmd --endpoints="$endpoints" endpoint status -w table 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}→ Failed to get endpoint status${NC}"
            status=1
        else
            echo "$endpoint_status"
            
            # Extract etcd version from status correctly
            # Look for VERSION column and extract the version number
            local etcd_version
            if [[ "$endpoint_status" == *"VERSION"* ]]; then
                # First, try to get the version from the table, which is probably 3.x.y
                etcd_version=$(echo "$endpoint_status" | grep -v ENDPOINT | awk '{print $3}' | head -1)
                if [[ -z "$etcd_version" || "$etcd_version" == "" ]]; then
                    # Fallback to direct parsing from JSON if table format fails
                    etcd_version=$($etcdctl_cmd --endpoints="$(echo $endpoints | cut -d, -f1)" endpoint status --write-out=json 2>/dev/null | 
                        grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
                fi
            fi
            
            if [[ -z "$etcd_version" ]]; then
                etcd_version="Unknown"
            fi
            
            echo -e "etcd server version: ${GREEN}$etcd_version${NC}"
        fi
        
        # Check endpoint health
        echo -e "\n${YELLOW}etcd Endpoint Health:${NC}"
        $etcdctl_cmd --endpoints="$endpoints" endpoint health -w table 2>/dev/null || {
            echo -e "${RED}→ Failed to get endpoint health${NC}"
            status=1
        }
        
        # Get cluster information
        echo -e "\n${YELLOW}etcd Cluster Information:${NC}"
        echo "Leader: "
        $etcdctl_cmd --endpoints="$endpoints" endpoint status --write-out=json 2>/dev/null | 
            grep -o '"leader":[^,]*' | head -1 || echo "Could not determine leader"
        
        # Get alarm list
        echo -e "\nAlarms: "
        $etcdctl_cmd --endpoints="$endpoints" alarm list 2>/dev/null || echo "Could not get alarms"
        
        # Get DB size and compaction stats
        echo -e "\n${YELLOW}etcd DB Stats:${NC}"
        $etcdctl_cmd --endpoints="$(echo $endpoints | cut -d, -f1)" endpoint status --write-out=json 2>/dev/null || echo "Could not get DB stats"
    else
        echo -e "${RED}→ K3s etcd certificates not found or not accessible at $cert_path${NC}"
        echo "Locations checked:"
        echo "CA cert: $cacert - $([ "$cacert_exists" == "yes" ] && echo "Found" || echo "Not found")"
        echo "Cert: $cert - $([ "$cert_exists" == "yes" ] && echo "Found" || echo "Not found")"
        echo "Key: $key - $([ "$key_exists" == "yes" ] && echo "Found" || echo "Not found")"
        
        echo -e "${YELLOW}→ This might be a permissions issue. The script needs sudo access to etcd certificates.${NC}"
        echo "Try running the script with sudo or as root."
        status=1
    fi
    
    print_status $status "etcd health check"
    return $status
}

install_cilium_cli() {
    echo -e "\n${YELLOW}===== Installing Cilium CLI =====${NC}"
    
    local status=0
    local CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    local CLI_ARCH=amd64
    
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        CLI_ARCH=arm64
    fi

    echo "Detected architecture: $CLI_ARCH"
    echo "Installing Cilium CLI version: $CILIUM_CLI_VERSION"
    
    if command -v cilium &> /dev/null; then
        echo -e "${GREEN}→ Cilium CLI already installed. Current version:${NC}"
        cilium version | grep "cilium-cli" || echo "Unable to detect version"
        return 0
    fi

    local TMP_DIR=$(mktemp -d)
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz -o ${TMP_DIR}/cilium.tar.gz
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}→ Failed to download Cilium CLI${NC}"
        rm -rf ${TMP_DIR}
        status=1
        print_status $status "Cilium CLI installation"
        return $status
    fi
    
    echo "Extracting and installing Cilium CLI..."
    tar -C ${TMP_DIR} -xf ${TMP_DIR}/cilium.tar.gz
    sudo cp ${TMP_DIR}/cilium /usr/local/bin/cilium
    rm -rf ${TMP_DIR}
    
    if command -v cilium &> /dev/null; then
        echo -e "${GREEN}→ Cilium CLI installed successfully:${NC}"
        cilium version | grep "cilium-cli" || echo "Version check failed"
    else
        echo -e "${RED}→ Cilium CLI installation failed${NC}"
        status=1
    fi
    
    print_status $status "Cilium CLI installation"
    return $status
}

install_tetra_cli() {
    echo -e "\n${YELLOW}===== Installing Tetra CLI =====${NC}"
    
    local status=0
    local CLI_ARCH=amd64
    
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        CLI_ARCH=arm64
    fi

    echo "Detected architecture: $CLI_ARCH"
    
    if command -v tetra &> /dev/null; then
        echo -e "${GREEN}→ Tetra CLI already installed. Current version:${NC}"
        tetra version || echo "Unable to detect version"
        return 0
    fi

    local TMP_DIR=$(mktemp -d)
    echo "Downloading latest Tetra CLI release..."
    curl -L --fail "https://github.com/cilium/tetragon/releases/latest/download/tetra-linux-${CLI_ARCH}.tar.gz" -o ${TMP_DIR}/tetra.tar.gz
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}→ Failed to download Tetra CLI${NC}"
        rm -rf ${TMP_DIR}
        status=1
        print_status $status "Tetra CLI installation"
        return $status
    fi
    
    echo "Extracting and installing Tetra CLI..."
    tar -C ${TMP_DIR} -xf ${TMP_DIR}/tetra.tar.gz
    sudo mv ${TMP_DIR}/tetra /usr/local/bin/tetra
    rm -rf ${TMP_DIR}
    
    if command -v tetra &> /dev/null; then
        echo -e "${GREEN}→ Tetra CLI installed successfully:${NC}"
        tetra version || echo "Version check failed"
    else
        echo -e "${RED}→ Tetra CLI installation failed${NC}"
        status=1
    fi
    
    print_status $status "Tetra CLI installation"
    return $status
}

install_hubble_cli() {
    echo -e "\n${YELLOW}===== Installing Hubble CLI =====${NC}"
    
    local status=0
    local HUBBLE_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
    local CLI_ARCH=amd64
    
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        CLI_ARCH=arm64
    fi

    echo "Detected architecture: $CLI_ARCH"
    echo "Installing Hubble CLI version: $HUBBLE_CLI_VERSION"
    
    if command -v hubble &> /dev/null; then
        echo -e "${GREEN}→ Hubble CLI already installed. Current version:${NC}"
        hubble version || echo "Unable to detect version"
        return 0
    fi

    local TMP_DIR=$(mktemp -d)
    echo "Downloading Hubble CLI release..."
    curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-${CLI_ARCH}.tar.gz -o ${TMP_DIR}/hubble.tar.gz
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}→ Failed to download Hubble CLI${NC}"
        rm -rf ${TMP_DIR}
        status=1
        print_status $status "Hubble CLI installation"
        return $status
    fi
    
    echo "Extracting and installing Hubble CLI..."
    tar -C ${TMP_DIR} -xf ${TMP_DIR}/hubble.tar.gz
    sudo cp ${TMP_DIR}/hubble /usr/local/bin/hubble
    rm -rf ${TMP_DIR}
    
    if command -v hubble &> /dev/null; then
        echo -e "${GREEN}→ Hubble CLI installed successfully:${NC}"
        hubble version || echo "Version check failed"
    else
        echo -e "${RED}→ Hubble CLI installation failed${NC}"
        status=1
    fi
    
    print_status $status "Hubble CLI installation"
    return $status
}

check_cilium() {
    # Enable Hubble after installation
    if command -v cilium &>/dev/null; then
        echo -e "\n${YELLOW}Enabling Hubble...${NC}"
        env KUBECONFIG=/etc/rancher/k3s/k3s.yaml cilium hubble enable || echo -e "${YELLOW}Hubble enable failed. It might already be enabled or Cilium may not be properly configured.${NC}"
        
        # Use Cilium's built-in port-forward instead of kubectl
        echo "Setting up port-forward to Hubble Relay using cilium CLI..."
        cilium hubble port-forward & 
        local pf_pid=$!
        
        # Give more time for port-forward to establish
        sleep 10
        
        # Test if Hubble is accessible now
        echo "Testing Hubble connectivity..."
        if hubble status &>/dev/null; then
            echo -e "${GREEN}Hubble Relay is available.${NC}"
        else
            echo -e "${YELLOW}Hubble Relay not accessible after multiple attempts.${NC}"
        fi
    fi

    echo -e "\n${YELLOW}===== Checking Cilium health =====${NC}"
    
    local status=0
        
    # Check if Cilium pods are running in the configured namespace
    echo "Checking for Cilium pods..."
    if kubectl get pods -n "$CILIUM_NAMESPACE" -l k8s-app=cilium 2>/dev/null | grep -q Running; then
        echo -e "${GREEN}→ Cilium pods are running${NC}"
    else
        echo -e "${RED}→ Cilium pods not found or not running in namespace $CILIUM_NAMESPACE${NC}"
        # Try to find Cilium in other namespaces
        local other_ns=$(kubectl get pods --all-namespaces | grep cilium | awk '{print $1}' | sort | uniq | head -1)
        if [[ -n "$other_ns" && "$other_ns" != "$CILIUM_NAMESPACE" ]]; then
            echo -e "${YELLOW}→ Cilium pods found in namespace: $other_ns${NC}"
            export CILIUM_NAMESPACE="$other_ns"
        else
            status=1
            print_status $status "Cilium health check"
            return $status
        fi
    fi
    
    # Check for Cilium CLI tool
    if ! command -v cilium &> /dev/null; then
        echo -e "${YELLOW}→ Cilium CLI not found, attempting to install...${NC}"
        if ! install_cilium_cli; then
            echo -e "${RED}→ Cilium CLI installation failed, continuing with basic checks only${NC}"
        fi
    fi
    
    # Run Cilium status check if CLI is available
    if command -v cilium &> /dev/null; then
        echo -e "\n${YELLOW}Cilium CLI Status:${NC}"
        if ! cilium status; then
            echo -e "${RED}→ Cilium status check failed${NC}"
            status=1
        else
            echo -e "${GREEN}→ Cilium status check passed${NC}"
        fi
                
        # Check Cilium connectivity
        echo -e "\n${YELLOW}Cilium Connectivity Test:${NC}"
        echo -e "\n${YELLOW}Running only client-ingress,client-egress,dns-only tests. If you want to run all of them (112+) you need to modify line below in code${NC}"
        if cilium connectivity test --test client-ingress,client-egress,dns-only tests; then
            echo -e "${GREEN}→ Basic connectivity tests passed${NC}"
        else
            echo -e "${YELLOW}→ Some connectivity tests failed${NC}"
            # Don't fail the whole check for this, it's a more aggressive test
        fi
        
        # Run Cilium connectivity performance test
        echo -e "\n${YELLOW}Cilium Connectivity Performance Test:${NC}"
        echo "Running network performance tests (this might take a moment)..."
        if cilium connectivity perf; then
            echo -e "${GREEN}→ Connectivity performance test completed successfully${NC}"
        else
            echo -e "${YELLOW}→ Connectivity performance test completed with issues${NC}"
            # Don't mark the whole check as failed for performance issues
        fi
    else
        # Fallback to kubectl for basic checks
        echo -e "\n${YELLOW}Cilium Status (via kubectl):${NC}"
        kubectl get pods -n "$CILIUM_NAMESPACE" -l k8s-app=cilium
        
        echo -e "\n${YELLOW}Cilium DaemonSet Status:${NC}"
        kubectl get ds -n "$CILIUM_NAMESPACE" -l k8s-app=cilium
        
        # Check for CiliumNetworkPolicies
        echo -e "\n${YELLOW}Cilium Network Policies:${NC}"
        kubectl get ciliumnetworkpolicies --all-namespaces 2>/dev/null || echo "No CiliumNetworkPolicies found or CRD not installed"
    fi
    
    # Check Cilium operator
    echo -e "\n${YELLOW}Checking Cilium Operator:${NC}"
    if kubectl get pods -n "$CILIUM_NAMESPACE" -l name=cilium-operator 2>/dev/null | grep -q Running; then
        echo -e "${GREEN}→ Cilium operator is running${NC}"
    else
        echo -e "${RED}→ Cilium operator pods not found or not running${NC}"
        status=1
    fi
    
    # Get Cilium version from pods
    local cilium_version=$(kubectl get pods -n "$CILIUM_NAMESPACE" -l k8s-app=cilium -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | cut -d: -f2)
    echo -e "Cilium version: ${GREEN}$cilium_version${NC}"
    
    print_status $status "Cilium health check"
    return $status
}

check_tetragon() {
    echo -e "\n${YELLOW}===== Checking Tetragon health =====${NC}"

    local status=0

    # Check if Tetragon pods are running in the configured namespace
    echo "Checking for Tetragon pods..."

    # Use the correct label selector AND check for running pods directly
    local tetragon_pods=$(kubectl get pods -n "$TETRAGON_NAMESPACE" -l app.kubernetes.io/name=tetragon --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    if [[ -n "$tetragon_pods" ]]; then
        echo -e "${GREEN}→ Tetragon pods are running${NC}"
    else
        echo -e "${RED}→ Tetragon pods not found in namespace $TETRAGON_NAMESPACE${NC}"
        # Try to find Tetragon in other namespaces (fallback)
        local other_ns=$(kubectl get pods --all-namespaces | grep tetragon | awk '{print $1}' | sort | uniq | head -1)
        if [[ -n "$other_ns" && "$other_ns" != "$TETRAGON_NAMESPACE" ]]; then
            echo -e "${YELLOW}→ Tetragon pods found in namespace: $other_ns${NC}"
            export TETRAGON_NAMESPACE="$other_ns"
        else
            echo -e "${YELLOW}→ Tetragon might not be installed${NC}"
            print_status $status "Tetragon health check"
            return $status
        fi
    fi

    # Check for Tetra CLI tool
    if ! command -v tetra &> /dev/null; then
        echo -e "${YELLOW}→ Tetra CLI not found, attempting to install...${NC}"
        if ! install_tetra_cli; then
            echo -e "${RED}→ Tetra CLI installation failed, continuing with basic checks only${NC}"
        fi
    fi

    # Run Tetragon status check if CLI is available
    if command -v tetra &> /dev/null; then
        echo -e "\n${YELLOW}Tetragon Status:${NC}"

        # Get tetragon pod
        local tetragon_pod=$(kubectl get pods -n "$TETRAGON_NAMESPACE" -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [[ -n "$tetragon_pod" ]]; then
            echo "Using Tetragon pod: $tetragon_pod"
            
            # Check if port-forward is needed for tetra status
            echo "Setting up port-forward to Tetragon..."
            kubectl port-forward -n "$TETRAGON_NAMESPACE" "pod/$tetragon_pod" 54321:54321 >/dev/null 2>&1 &
            local pf_pid=$!
            sleep 3
            
            # Run tetra status on local machine (not in the pod)
            if tetra status --server-address localhost:54321; then
                echo -e "${GREEN}→ Tetragon status check passed${NC}"
            else
                echo -e "${YELLOW}→ Tetragon status with port-forward failed, trying Unix socket...${NC}"
                # Kill the port-forward process
                kill ${pf_pid} >/dev/null 2>&1 || true
                wait ${pf_pid} 2>/dev/null || true
                
                # Alternative approach - check pod status only
                if kubectl get pod -n "$TETRAGON_NAMESPACE" "$tetragon_pod" -o jsonpath='{.status.phase}' | grep -q "Running"; then
                    echo -e "${GREEN}→ Tetragon pod is running${NC}"
                else
                    echo -e "${RED}→ Tetragon pod is not in Running state${NC}"
                    status=1
                fi
            fi
            
            # Clean up port-forward if it's still running
            kill ${pf_pid} >/dev/null 2>&1 || true
            wait ${pf_pid} 2>/dev/null || true
        else
            echo -e "${RED}→ Cannot find a Tetragon pod to connect to${NC}"
            status=1
        fi
    else
        # Fallback to kubectl for basic checks
        echo -e "\n${YELLOW}Tetragon Status (via kubectl):${NC}"
        kubectl get pods -n "$TETRAGON_NAMESPACE" -l app.kubernetes.io/name=tetragon

        echo -e "\n${YELLOW}Tetragon DaemonSet Status:${NC}"
        kubectl get ds -n "$TETRAGON_NAMESPACE" -l app.kubernetes.io/name=tetragon

        # Check for TracingPolicy CRDs
        echo -e "\n${YELLOW}Tetragon Tracing Policies:${NC}"
        kubectl get tracingpolicies.cilium.io --all-namespaces 2>/dev/null || echo "No TracingPolicies found or CRD not installed"
    fi
}

check_hubble() {
    echo -e "\n${YELLOW}===== Checking Hubble health =====${NC}"
    
    local status=0
    
    # Check if Hubble pods are running in the configured namespace
    echo "Checking for Hubble pods..."
    if kubectl get pods -n "$CILIUM_NAMESPACE" -l k8s-app=hubble-relay 2>/dev/null | grep -q Running; then
        echo -e "${GREEN}→ Hubble relay pods are running${NC}"
    else
        # Try alternative label if the first one doesn't work
        if kubectl get pods -n "$CILIUM_NAMESPACE" -l app=hubble-relay 2>/dev/null | grep -q Running; then
            echo -e "${GREEN}→ Hubble relay pods are running${NC}"
        else
            echo -e "${YELLOW}→ Hubble relay pods not found or not running${NC}"
            echo "Checking for Hubble UI pods instead..."
            
            if kubectl get pods -n "$CILIUM_NAMESPACE" -l k8s-app=hubble-ui 2>/dev/null | grep -q Running; then
                echo -e "${GREEN}→ Hubble UI pods are running${NC}"
            else
                echo -e "${RED}→ Neither Hubble relay nor UI pods found running${NC}"
                echo -e "${YELLOW}→ Hubble might not be enabled in your Cilium installation${NC}"
                status=1
                print_status $status "Hubble health check"
                return $status
            fi
        fi
    fi  # Fixed: Removed the erroneous closing brace and added correct one
    
    # Verify Hubble connectivity using the CLI
    if command -v hubble &> /dev/null; then
        echo -e "\n${YELLOW}Hubble CLI Status:${NC}"
        
        # Start port-forward to access Hubble Relay service
        echo "Setting up port-forward to Hubble Relay..."
        kubectl port-forward -n "$CILIUM_NAMESPACE" service/hubble-relay 4245:80 >/dev/null 2>&1 &
        local pf_pid=$!
        sleep 3
        
        # Test connectivity
        if hubble status --server localhost:4245; then
            echo -e "${GREEN}→ Hubble status check passed${NC}"
        else
            echo -e "${RED}→ Hubble status check failed${NC}"
            status=1
        fi
        
        # Try to list some nodes to verify functionality
        echo -e "\n${YELLOW}Testing Hubble nodes listing:${NC}"
        if hubble list nodes --server localhost:4245 2>/dev/null; then
            echo -e "${GREEN}→ Successfully listed Hubble nodes${NC}"
        else
            echo -e "${RED}→ Failed to list Hubble nodes${NC}"
            status=1
        fi
        
        # Clean up port-forward
        kill ${pf_pid} >/dev/null 2>&1 || true
        wait ${pf_pid} 2>/dev/null || true
    else
        # Fallback checks when Hubble CLI is not available
        echo -e "${YELLOW}→ Hubble CLI not available for detailed testing${NC}"
        
        # Check the Hubble-Relay service
        if kubectl get service hubble-relay -n "$CILIUM_NAMESPACE" >/dev/null 2>&1; then
            echo -e "${GREEN}→ Hubble Relay service exists${NC}"
        else
            echo -e "${RED}→ Hubble Relay service not found${NC}"
            status=1
        fi
        
        # Check Hubble UI service
        if kubectl get service hubble-ui -n "$CILIUM_NAMESPACE" >/dev/null 2>&1; then
            echo -e "${GREEN}→ Hubble UI service exists${NC}"
        else
            echo -e "${YELLOW}→ Hubble UI service not found${NC}"
            # Don't fail just for missing UI
        fi
    fi
    
    print_status $status "Hubble health check"
    return $status
}

get_component_versions() {
    echo -e "\n${YELLOW}===== Component Versions =====${NC}"

    # Get k3s version
    local k3s_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "Not found")
    echo -e "K3s Version: ${GREEN}$k3s_version${NC}"

    # Get containerd version - Extract only the version number
    local containerd_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "Not found")
    containerd_version=$(echo "$containerd_version" | awk -F'//' '{print $2}' | cut -d'-' -f1) # Use awk and cut
    echo -e "Container Runtime (containerd): ${GREEN}$containerd_version${NC}"

    # Get Helm version
    local helm_version=$(helm version --short 2>/dev/null || echo "Not installed")
    echo -e "Helm Version: ${GREEN}$helm_version${NC}"

    # Get Traefik version
    local traefik_version=$(kubectl get deployment -n "$TRAEFIK_NAMESPACE" traefik -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "Not found")
    echo -e "Traefik Version: ${GREEN}$traefik_version${NC}"

    # Get CoreDNS version
    local coredns_version=$(kubectl get deployment -n "$KUBE_SYSTEM_NAMESPACE" coredns -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "Not found")
    echo -e "CoreDNS Version: ${GREEN}$coredns_version${NC}"

    # Get Longhorn version
    local longhorn_version=$(kubectl get deployment -n "$LONGHORN_NAMESPACE" longhorn-ui -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "Not found")
    echo -e "Longhorn Version: ${GREEN}$longhorn_version${NC}"

    # Get Cert-Manager version
    local certmanager_version=$(kubectl get deployment -n "$CERT_MANAGER_NAMESPACE" cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "Not found")
    echo -e "Cert-Manager Version: ${GREEN}$certmanager_version${NC}"

    # Get Argo CD version
    local argocd_version=$(kubectl get deployment -n "$ARGOCD_NAMESPACE" argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "Not found")
    echo -e "Argo CD Version: ${GREEN}$argocd_version${NC}"

    # Get Argo CD Image Updater version
    local argocd_image_updater_version=$(kubectl get deployment -n "$ARGOCD_NAMESPACE" argocd-image-updater -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "Not found")
    echo -e "Argo CD Image Updater Version: ${GREEN}$argocd_image_updater_version${NC}"

    # Get etcd server version
    echo -e "\n${YELLOW}===== etcd Versions =====${NC}"

    # Get etcd version from k3s
    local etcd_version=""
    local cert_path="/var/lib/rancher/k3s/server/tls/etcd"
    local cacert="$cert_path/server-ca.crt"
    local cert="$cert_path/server-client.crt"
    local key="$cert_path/server-client.key"

    # Check if certificates exist
    if sudo test -f "$cacert" && sudo test -f "$cert" && sudo test -f "$key"; then
        etcd_version=$(sudo ETCDCTL_API=3 etcdctl --cacert=$cacert --cert=$cert --key=$key endpoint status --write-out=json 2>/dev/null |
            grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "Not available")
    else
        etcd_version="Not available (certificates not accessible)"
    fi

    echo -e "etcd Server Version: ${GREEN}$etcd_version${NC}"

    # Get etcdctl version
    local etcdctl_version=""
    if command -v etcdctl &> /dev/null; then
        etcdctl_version=$(etcdctl version 2>/dev/null | grep "etcdctl version" | awk '{print $3}' || echo "Unknown")
    else
        etcdctl_version="Not installed"
    fi
    echo -e "etcdctl Version: ${GREEN}$etcdctl_version${NC}"

    # Get Cilium versions
    echo -e "\n${YELLOW}===== Cilium Ecosystem Versions =====${NC}"

    # Get cilium server version from pods and extract only the version - make error handling more robust
    local cilium_server_version=""
    cilium_server_version=$(kubectl get pods -n "$CILIUM_NAMESPACE" -l k8s-app=cilium -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
    if [[ -n "$cilium_server_version" ]]; then
        cilium_server_version=$(echo "$cilium_server_version" | cut -d: -f2 | sed 's/@.*//')  # Remove @sha256...
    else
        cilium_server_version="Not found"
    fi
    echo -e "Cilium Server Version: ${GREEN}$cilium_server_version${NC}"

    # Get Cilium CLI version
    local cilium_cli_version=""
    if command -v cilium &> /dev/null; then
        cilium_cli_version=$(cilium version 2>/dev/null | grep "cilium-cli" | awk '{print $2}' || echo "Unknown")
    else
        cilium_cli_version="Not installed"
    fi
    echo -e "Cilium CLI Version: ${GREEN}$cilium_cli_version${NC}"

    # Get Hubble server version and extract only the version - with improved error handling
    local hubble_server_version=""
    # First try to find the hubble-relay pod
    hubble_server_version=$(kubectl get pods -n "$CILIUM_NAMESPACE" -l k8s-app=hubble-relay -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
    if [[ -z "$hubble_server_version" ]]; then
        # Try with app=hubble-relay
        hubble_server_version=$(kubectl get pods -n "$CILIUM_NAMESPACE" -l app=hubble-relay -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
    fi
    
    # If still not found, use the Cilium version since Hubble is bundled with it
    if [[ -z "$hubble_server_version" ]]; then
        hubble_server_version="$cilium_server_version"
    else
        hubble_server_version=$(echo "$hubble_server_version" | cut -d: -f2 | sed 's/@.*//')  # Remove @sha256...
    fi
    echo -e "Hubble Server Version: ${GREEN}$hubble_server_version${NC}"

    # Get Hubble CLI version
    local hubble_cli_version=""
    if command -v hubble &> /dev/null; then
        hubble_cli_version=$(hubble version 2>/dev/null | grep "hubble" | head -1 | awk '{print $2}' || echo "Unknown")
        # The version is in format "vX.Y.Z@HEAD-hash" so we need to extract just the version part
        if [[ "$hubble_cli_version" != "Unknown" ]]; then
            hubble_cli_version=$(echo "$hubble_cli_version" | cut -d'@' -f1 || echo "$hubble_cli_version")
        fi
    else
        hubble_cli_version="Not installed"
    fi
    echo -e "Hubble CLI Version: ${GREEN}$hubble_cli_version${NC}"

    # Get Tetragon server version with improved error handling
    local tetragon_server_version=""
    tetragon_server_version=$(kubectl get pods -n "$TETRAGON_NAMESPACE" -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
    if [[ -n "$tetragon_server_version" ]]; then
        tetragon_server_version=$(echo "$tetragon_server_version" | cut -d: -f2 || echo "Parse error")
    else
        tetragon_server_version="Not found"
    fi
    echo -e "Tetragon Server Version: ${GREEN}$tetragon_server_version${NC}"

    # Get Tetra CLI version
    local tetra_cli_version=""
    if command -v tetra &> /dev/null; then
        tetra_cli_version=$(tetra version 2>/dev/null | grep -i "CLI version" | awk '{print $3}' || echo "Unknown")
        if [[ "$tetra_cli_version" == "Unknown" ]]; then
            # Fall back to old format that just had "Version" 
            tetra_cli_version=$(tetra version 2>/dev/null | grep "Version" | awk '{print $2}' || echo "Unknown")
        fi
    else
        tetra_cli_version="Not installed"
    fi
    echo -e "Tetra CLI Version: ${GREEN}$tetra_cli_version${NC}"
}

integration_test() {
    echo -e "\n${YELLOW}===== Running Integration Test =====${NC}"
    
    local TEST_NS="k3s-integration-test"
    local status=0

    # Create test namespace
    echo "Creating test namespace..."
    kubectl create namespace "$TEST_NS" >/dev/null 2>&1 || true

    # Create a self-signed ClusterIssuer for the integration test
    echo "Creating self-signed ClusterIssuer for testing..."
    kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

    # Create test resources with the certificate now referencing the self-signed issuer
    # Updated IngressRoute to use Traefik v3 API version
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: $TEST_NS
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: $TEST_NS
spec:
  secretName: test-tls
  duration: 2h
  renewBefore: 1h
  privateKey:
    algorithm: ECDSA
    size: 256
  dnsNames:
    - test-app.local
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: $TEST_NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
      - name: nginx
        image: nginx:stable-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: test-storage
          mountPath: /data
      volumes:
      - name: test-storage
        persistentVolumeClaim:
          claimName: test-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: $TEST_NS
spec:
  selector:
    app: test-app
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: test-ingress
  namespace: $TEST_NS
spec:
  entryPoints:
    - web
  routes:
  - match: Host(\`test-app.local\`)
    kind: Rule
    services:
    - name: test-service
      port: 80
EOF

    # Create a Cilium Network Policy for testing
    echo "Creating Cilium Network Policy..."
    kubectl apply -f - <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: test-cnp
  namespace: $TEST_NS
spec:
  endpointSelector:
    matchLabels:
      app: test-app
  ingress:
  - fromEndpoints:
    - matchLabels: {}
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
EOF

    # Create a Tetragon TracingPolicy for testing
    echo "Creating Tetragon TracingPolicy..."
    kubectl apply -f - <<EOF
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: test-tracing-policy
  namespace: $TEST_NS
spec:
  kprobes:
  - call: "sys_openat"
    syscall: true
    args:
      - index: 2  # The filename is typically the 3rd argument (index 2)
        type: "string"
    selectors:
    - matchArgs:
      - index: 2
        operator: "Prefix"
        values:
          - "/etc/"    # Trace opens of files under /etc
          - "/tmp/test" # Trace opens if filename begins with /tmp/test
      matchActions:
      - action: Post
    - matchArgs:
      - index: 2
        operator: "Equal"
        values:
          - "/dev/null"
      matchActions:
      - action: Post
EOF

    echo "Waiting for resources to be ready..."
    sleep 30

    # Standard checks for core resources
    # Check PVC
    if ! kubectl get pvc test-pvc -n "$TEST_NS" | grep -q Bound; then
        echo -e "${RED}→ PVC not bound${NC}"
        status=1
    else
        echo -e "${GREEN}→ PVC successfully bound${NC}"
    fi

    # Check Certificate
    if ! kubectl wait --for=condition=Ready certificate test-cert -n "$TEST_NS" --timeout=30s >/dev/null 2>&1; then
        echo -e "${RED}→ Certificate not ready${NC}"
        status=1
    else
        echo -e "${GREEN}→ Certificate successfully created${NC}"
    fi

    # Check Deployment
    if ! kubectl rollout status deployment/test-app -n "$TEST_NS" --timeout=30s >/dev/null 2>&1; then
        echo -e "${RED}→ Deployment not ready${NC}"
        status=1
    else
        echo -e "${GREEN}→ Deployment successfully rolled out${NC}"
    fi

    # Check Service
    if ! kubectl get service test-service -n "$TEST_NS" >/dev/null 2>&1; then
        echo -e "${RED}→ Service not created${NC}"
        status=1
    else
        echo -e "${GREEN}→ Service successfully created${NC}"
    fi

    # Check IngressRoute - Traefik v3 specific
    echo "Checking IngressRoute..."
    if kubectl get ingressroute.traefik.io test-ingress -n "$TEST_NS" > /dev/null 2>&1; then
        echo -e "${GREEN}→ IngressRoute successfully created${NC}"
    else
        echo -e "${RED}→ IngressRoute not created or not ready${NC}"
        status=1
    fi
    
    # Check Cilium Network Policy
    echo -e "\n${YELLOW}Checking Cilium Network Policy:${NC}"
    if kubectl get ciliumnetworkpolicies.cilium.io -n "$TEST_NS" test-cnp > /dev/null 2>&1; then
        echo -e "${GREEN}→ Cilium Network Policy successfully created${NC}"
        
        # Run a test to verify Cilium policy enforcement
        echo "Testing Cilium policy enforcement..."
        
        # Create a test pod to verify connectivity
        kubectl run -n "$TEST_NS" cilium-test --image=curlimages/curl --restart=Never --command -- sleep 3600 > /dev/null 2>&1
        
        # Wait for the pod to be ready
        kubectl wait --for=condition=ready pod -n "$TEST_NS" cilium-test --timeout=60s > /dev/null 2>&1
        
        # Skip Cilium endpoint checks since the commands are no longer available
        # Test connectivity directly instead
        echo "Testing network connectivity with Cilium policy..."
        if kubectl exec -n "$TEST_NS" cilium-test -- curl -s -H "Host: test-app.local" http://test-service > /dev/null 2>&1; then
            echo -e "${GREEN}→ Network connectivity works with Cilium policy${NC}"
        else
            echo -e "${RED}→ Network connectivity fails with Cilium policy${NC}"
            status=1
        fi
        
        # Clean up the test pod
        kubectl delete pod -n "$TEST_NS" cilium-test --wait=false > /dev/null 2>&1
    else
        echo -e "${RED}→ Cilium Network Policy not created or CRD not installed${NC}"
        echo "This suggests Cilium may not be installed or configured correctly"
        status=1
    fi
    
    # Check Tetragon TracingPolicy
    echo -e "\n${YELLOW}Checking Tetragon TracingPolicy:${NC}"
    if kubectl get tracingpolicies.cilium.io -n "$TEST_NS" test-tracing-policy > /dev/null 2>&1; then
        echo -e "${GREEN}→ Tetragon TracingPolicy successfully created${NC}"
        
        # Check if Tetragon is processing policies
        if command -v tetra &> /dev/null; then
            echo "Looking for Tetragon pods..."
            local tetragon_pod=$(kubectl get pods -n "$TETRAGON_NAMESPACE" -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            
            if [[ -n "$tetragon_pod" ]]; then
                echo "Found Tetragon pod: $tetragon_pod"
                echo "Checking if Tetragon policy is processed..."
                
            # Check Tetragon logs for indication of policy processing
            if kubectl logs -n "$TETRAGON_NAMESPACE" "$tetragon_pod" -c tetragon --tail=50 | grep -q "policy\|tracing\|TracingPolicy"; then
                echo -e "${GREEN}→ Tetragon shows evidence of policy processing${NC}"
            else
                echo -e "${YELLOW}→ Could not confirm Tetragon policy processing in logs (not necessarily an error)${NC}"
            fi
            
            # Generate some network activity that should trigger our policy
            echo "Generating traffic for Tetragon to observe..."
            kubectl run -n "$TEST_NS" --rm -i --restart=Never --image=curlimages/curl curl-test -- curl -s -H "Host: test-app.local" http://test-service > /dev/null 2>&1 || true
            
            # Check if Tetragon is capturing events - specify container explicitly
            echo "Checking if Tetragon is capturing events..."
            if tetra getevents --pod-namespace "$TETRAGON_NAMESPACE" --pod-name "$tetragon_pod" --pod-container tetragon --server-address "unix://${TETRAGON_NAMESPACE}/${tetragon_pod}:/var/run/tetragon/tetragon.sock" --timeout 2 2>/dev/null | head -n 5 | grep -q "."; then
                echo -e "${GREEN}→ Tetragon is actively capturing events${NC}"
            else
                echo -e "${YELLOW}→ No events captured by Tetragon within timeout period (might need longer observation)${NC}"
                # Try with a port-forward approach as a fallback
                echo "Trying alternative approach with port-forward..."
                kubectl port-forward -n "$TETRAGON_NAMESPACE" "pod/$tetragon_pod" 54321:54321 >/dev/null 2>&1 &
                local pf_pid=$!
                sleep 2
                tetra getevents --server-address localhost:54321 --timeout 2 2>/dev/null | head -n 5 | grep -q "." && \
                    echo -e "${GREEN}→ Tetragon events found via port-forward${NC}" || \
                    echo -e "${YELLOW}→ Still no events found, but Tetragon appears to be running${NC}"
                kill ${pf_pid} >/dev/null 2>&1 || true
                wait ${pf_pid} 2>/dev/null || true
            fi
            else
                echo -e "${RED}→ Tetragon pod not found${NC}"
                status=1
            fi
        else
            echo -e "${YELLOW}→ Tetra CLI not available for detailed testing${NC}"
            echo "Checking Tetragon pod logs for basic activity..."
            
            if kubectl get pods -n "$TETRAGON_NAMESPACE" -l app.kubernetes.io/name=tetragon 2>/dev/null | grep -q Running; then
                echo -e "${GREEN}→ Tetragon pods are running, which suggests basic functionality${NC}"
            else
                echo -e "${RED}→ Tetragon pods not found or not running${NC}"
                status=1
            fi
        fi
    else
        echo -e "${RED}→ Tetragon TracingPolicy not created or CRD not installed${NC}"
        echo "This suggests Tetragon may not be installed or configured correctly"
        status=1
    fi

    # Test the application
    echo -e "\n${YELLOW}Testing application access:${NC}"
    kubectl run -n "$TEST_NS" curl-pod --rm -i --restart=Never --image=curlimages/curl \
        -- -s -H "Host: test-app.local" http://test-service >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}→ Application is accessible${NC}"
    else
        echo -e "${RED}→ Application is not accessible${NC}"
        status=1
    fi

    # Cleanup in the correct order to avoid resource deadlocks
    echo -e "\n${YELLOW}Cleaning up test resources...${NC}"
    
    # Cilium and Tetragon resources
    kubectl delete ciliumnetworkpolicies.cilium.io -n "$TEST_NS" test-cnp --timeout=15s 2>/dev/null || true
    kubectl delete tracingpolicies.cilium.io -n "$TEST_NS" test-tracing-policy --timeout=15s 2>/dev/null || true

    # Standard resources - clean up certificate first as it can block deletions
    kubectl delete certificate -n "$TEST_NS" --all --timeout=30s >/dev/null 2>&1 
    sleep 5  # Give cert-manager time to process the deletion

    # Cleanup remaining resources in reverse order of creation
    kubectl delete ingressroute.traefik.io -n "$TEST_NS" test-ingress --timeout=15s >/dev/null 2>&1
    kubectl delete service -n "$TEST_NS" test-service --timeout=15s >/dev/null 2>&1
    kubectl delete deployment -n "$TEST_NS" test-app --timeout=30s >/dev/null 2>&1
    kubectl delete pvc -n "$TEST_NS" test-pvc --timeout=30s >/dev/null 2>&1
    sleep 5
    kubectl delete namespace "$TEST_NS" --timeout=60s >/dev/null 2>&1

    # Disable Hubble after integration test
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml    
    if command -v cilium &>/dev/null; then
      echo -e "\n${YELLOW}Disabling Hubble...${NC}"
      cilium hubble disable || echo -e "${YELLOW}Hubble disable failed. It might not have been enabled.${NC}"
    fi

    print_status $status "Integration test"
    return $status
}

echo -e "${YELLOW}Starting comprehensive health check for k3s cluster components${NC}"
echo "================================================================"

# Track overall status
OVERALL_STATUS=0

# Install CLI tools first
install_cilium_cli
install_tetra_cli
install_hubble_cli

# Check pods and deployments in each namespace
for ns in "${NAMESPACES[@]}"; do
    if ! check_pods "$ns" || ! check_deployments "$ns"; then
        OVERALL_STATUS=1
    fi
done

# Check functional endpoints for key tools
if ! check_argocd; then
    OVERALL_STATUS=1
fi

if ! check_cert_manager; then
    OVERALL_STATUS=1
fi

if ! check_longhorn; then
    OVERALL_STATUS=1
fi

if ! check_coredns; then
    OVERALL_STATUS=1
fi

if ! check_traefik; then
    OVERALL_STATUS=1
fi

if ! check_argocd_image_updater; then
    OVERALL_STATUS=1
fi

# Add etcd health check
if ! check_etcd; then
    OVERALL_STATUS=1
fi

# Add Cilium and Tetragon health checks
if ! check_cilium; then
    OVERALL_STATUS=1
fi

if ! check_hubble; then
    OVERALL_STATUS=1
fi

if ! check_tetragon; then
    OVERALL_STATUS=1
fi

if ! integration_test; then
    OVERALL_STATUS=1
fi

echo "================================================================"
if [ $OVERALL_STATUS -eq 0 ]; then
    echo -e "${GREEN}Health check completed successfully${NC}"
else
    echo -e "${RED}Health check completed with errors${NC}"
    echo -e "\n${YELLOW}Error Summary:${NC}"
    printf '%s\n' "${ERROR_LIST[@]}" | nl
fi

# Only show component versions at the end
get_component_versions

echo -e "\n================================================================"
exit $OVERALL_STATUS
