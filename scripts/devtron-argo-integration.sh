#!/bin/bash
set -euo pipefail

NAMESPACE="${DEVTRON_NAMESPACE:-devtroncd}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_SERVER="${ARGOCD_SERVER:-argocd-server.argocd}"

log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_success() { echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    local deps=("kubectl" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "$dep is not installed"
            exit 1
        fi
    done

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

validate_argocd_connection() {
    log_info "Validating Argo CD connection from Devtron cluster..."

    if kubectl get applications.argoproj.io -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        local app_count
        app_count=$(kubectl get applications.argoproj.io -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
        log_success "Argo CD is accessible with $app_count applications"
        return 0
    else
        log_error "Cannot access Argo CD applications"
        return 1
    fi
}

show_devtron_instructions() {
    cat << 'EOF'

================================================================================
                        Devtron Argo CD Integration
================================================================================

Argo CD apps should now be visible in Devtron UI:

1. Open Devtron Dashboard
2. Navigate to: Apps > ArgoCD Apps (or External ArgoCD)
3. The connected cluster's Argo CD applications will be listed

For external Argo CD clusters:
- Go to Global Configurations > Clusters & Environments
- Add the cluster where Argo CD is running

================================================================================
EOF
}

main() {
    log_info "Starting Devtron Argo CD integration check..."

    check_prerequisites
    validate_argocd_connection
    show_devtron_instructions

    log_success "Integration check complete!"
}

main "$@"