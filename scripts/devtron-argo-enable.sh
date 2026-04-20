#!/bin/bash
set -euo pipefail

NAMESPACE="${DEVTRON_NAMESPACE:-devtroncd}"
CONFIGMAP_NAME="dashboard-cm"
DEVTRON_DASHBOARD_LABEL="app=dashboard"

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Devtron namespace '$NAMESPACE' not found"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

enable_argo_cd_app_listing() {
    log_info "Enabling Argo CD app listing in Devtron..."

    local configmap_json
    configmap_json=$(kubectl get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o json 2>/dev/null) || {
        log_error "ConfigMap $CONFIGMAP_NAME not found in namespace $NAMESPACE"
        exit 1
    }

    local current_value
    current_value=$(echo "$configmap_json" | jq -r '.data.ENABLE_EXTERNAL_ARGO_CD // "false"')

    if [[ "$current_value" == "true" ]]; then
        log_info "ENABLE_EXTERNAL_ARGO_CD is already set to 'true'"
        return 0
    fi

    kubectl patch configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" \
        --type merge \
        -p '{"data":{"ENABLE_EXTERNAL_ARGO_CD":"true"}}'

    log_info "Successfully patched dashboard-cm with ENABLE_EXTERNAL_ARGO_CD=true"
}

restart_dashboard_pod() {
    log_info "Restarting Devtron dashboard pod..."

    local dashboard_pod
    dashboard_pod=$(kubectl get pods -n "$NAMESPACE" -l "$DEVTRON_DASHBOARD_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || {
        log_error "No dashboard pod found in namespace $NAMESPACE"
        exit 1
    }

    if [[ -z "$dashboard_pod" ]]; then
        log_error "Dashboard pod not found"
        exit 1
    fi

    log_info "Deleting dashboard pod: $dashboard_pod"
    kubectl delete pod "$dashboard_pod" -n "$NAMESPACE" --wait=false

    log_info "Waiting for new dashboard pod to be ready..."
    kubectl wait --for=condition=ready pod -l "$DEVTRON_DASHBOARD_LABEL" -n "$NAMESPACE" \
        --timeout=300s || {
        log_error "Dashboard pod did not become ready in time"
        exit 1
    }

    log_info "Dashboard pod restarted successfully"
}

validate_integration() {
    log_info "Validating Argo CD app listing integration..."

    local configmap_json
    configmap_json=$(kubectl get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o json)
    local argo_enabled
    argo_enabled=$(echo "$configmap_json" | jq -r '.data.ENABLE_EXTERNAL_ARGO_CD // "false"')

    if [[ "$argo_enabled" == "true" ]]; then
        log_info "VALIDATION PASSED: ENABLE_EXTERNAL_ARGO_CD is set to 'true'"
        log_info "ArgoCD Apps tab should now appear in Devtron UI"
        return 0
    else
        log_error "VALIDATION FAILED: ENABLE_EXTERNAL_ARGO_CD is not set correctly"
        exit 1
    fi
}

main() {
    log_info "Starting Devtron Argo CD app listing enablement..."

    check_prerequisites
    enable_argo_cd_app_listing
    restart_dashboard_pod
    validate_integration

    log_info "Devtron Argo CD app listing enabled successfully!"
}

main "$@"