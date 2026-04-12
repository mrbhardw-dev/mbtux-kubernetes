#!/bin/bash
#
# Rancher 2.14.0 Automated Deployment Script
# Deploys Rancher HA with Fleet GitOps, Monitoring, and data-cluster registration
#
# Usage: ./deploy-rancher-fleet.sh
#

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# Configuration - Edit these values before running
# ────────────────────────────────────────────────────────────────

RANCHER_VERSION="2.14.0"
RANCHER_HOSTNAME="rancher.mbtux.com"
RANCHER_BOOTSTRAP_PASSWORD="nFtMpT^z!1B&la^WDiBd"
RANCHER_REPLICAS=3

GIT_REPO_URL="https://github.com/mrbhardw-dev/mbtux-kubernetes.git"
GIT_BRANCH="main"
GIT_USERNAME=""
GIT_PASSWORD=""

GRAFANA_HOSTNAME="grafana.mbtux.com"
GRAFANA_PASSWORD="CHANGE_ME_GRAFANA_PASSWORD"

STORAGE_CLASS="proxmox-zfs"
METALLB_IP="192.168.0.210"

MGMT_CONTEXT="mgmt-cluster"
DATA_CONTEXT="data-cluster"

MONITORING_CHART_VERSION="66.2.2"
PROMETHEUS_RETENTION="15d"
PROMETHEUS_STORAGE="50Gi"
ALERTMANAGER_STORAGE="10Gi"
GRAFANA_STORAGE="10Gi"

LOG_FILE="/tmp/rancher-deploy-$(date +%Y%m%d-%H%M%S).log"

# ────────────────────────────────────────────────────────────────
# Color output helpers
# ────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}" | tee -a "$LOG_FILE"; }

# ────────────────────────────────────────────────────────────────
# Pre-flight checks
# ────────────────────────────────────────────────────────────────

preflight_checks() {
    step "Pre-flight Checks"

    local failed=0

    # Check kubectl
    if command -v kubectl &>/dev/null; then
        local kver
        kver=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1 | cut -d'"' -f4)
        success "kubectl found: ${kver}"
    else
        error "kubectl not found. Install kubectl v1.31.x+"
        failed=1
    fi

    # Check helm
    if command -v helm &>/dev/null; then
        local hver
        hver=$(helm version --short 2>/dev/null)
        success "helm found: ${hver}"
    else
        error "helm not found. Install helm v3.16.x+"
        failed=1
    fi

    # Check curl
    if command -v curl &>/dev/null; then
        success "curl found"
    else
        error "curl not found"
        failed=1
    fi

    # Check jq
    if command -v jq &>/dev/null; then
        success "jq found"
    else
        error "jq not found. Install jq 1.6+"
        failed=1
    fi

    # Check mgmt-cluster connectivity
    if kubectl --context "$MGMT_CONTEXT" cluster-info &>/dev/null; then
        success "mgmt-cluster reachable via context: $MGMT_CONTEXT"
    else
        error "Cannot reach mgmt-cluster with context: $MGMT_CONTEXT"
        error "Ensure kubeconfig has the correct context configured"
        failed=1
    fi

    # Check nodes on mgmt-cluster
    local node_count
    node_count=$(kubectl --context "$MGMT_CONTEXT" get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "$node_count" -ge 1 ]]; then
        success "mgmt-cluster has ${node_count} node(s)"
    else
        error "mgmt-cluster has no nodes"
        failed=1
    fi

    # Check nodes on data-cluster
    if kubectl --context "$DATA_CONTEXT" cluster-info &>/dev/null; then
        success "data-cluster reachable via context: $DATA_CONTEXT"
        local data_nodes
        data_nodes=$(kubectl --context "$DATA_CONTEXT" get nodes --no-headers 2>/dev/null | wc -l)
        success "data-cluster has ${data_nodes} node(s)"
    else
        warn "data-cluster not reachable. Cluster registration will be skipped."
        warn "You can register it later via Rancher UI."
    fi

    # Check MetalLB
    if kubectl --context "$MGMT_CONTEXT" get pods -n metallb-system &>/dev/null; then
        local mlb_pods
        mlb_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n metallb-system --no-headers 2>/dev/null | grep -c Running || true)
        if [[ "$mlb_pods" -gt 0 ]]; then
            success "MetalLB running (${mlb_pods} pods)"
        else
            warn "MetalLB namespace exists but no running pods"
        fi
    else
        warn "MetalLB not detected. Ingress may not get an external IP."
    fi

    # Check Nginx Ingress
    if kubectl --context "$MGMT_CONTEXT" get pods -n ingress-nginx &>/dev/null; then
        local nginx_pods
        nginx_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n ingress-nginx --no-headers 2>/dev/null | grep -c Running || true)
        if [[ "$nginx_pods" -gt 0 ]]; then
            success "Nginx Ingress running (${nginx_pods} pods)"
        else
            warn "Nginx Ingress namespace exists but no running pods"
        fi
    else
        warn "Nginx Ingress not detected. Rancher UI may not be accessible externally."
    fi

    # Check cert-manager
    if kubectl --context "$MGMT_CONTEXT" get pods -n cert-manager &>/dev/null; then
        local cm_pods
        cm_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cert-manager --no-headers 2>/dev/null | grep -c Running || true)
        if [[ "$cm_pods" -gt 0 ]]; then
            success "cert-manager running (${cm_pods} pods)"
        else
            warn "cert-manager namespace exists but no running pods"
        fi
    else
        warn "cert-manager not detected. TLS certificates may not be auto-provisioned."
    fi

    # Check StorageClass
    if kubectl --context "$MGMT_CONTEXT" get storageclass "$STORAGE_CLASS" &>/dev/null; then
        success "StorageClass '${STORAGE_CLASS}' exists"
    else
        warn "StorageClass '${STORAGE_CLASS}' not found. Monitoring persistence may fail."
    fi

    # Check git credentials
    if [[ -z "$GIT_USERNAME" || -z "$GIT_PASSWORD" ]]; then
        warn "Git credentials not set in script. You will be prompted."
    fi

    if [[ "$failed" -eq 1 ]]; then
        error "Pre-flight checks failed. Fix the issues above and re-run."
        exit 1
    fi

    success "All pre-flight checks passed"
}

# ────────────────────────────────────────────────────────────────
# Prompt for missing values
# ────────────────────────────────────────────────────────────────

prompt_values() {
    step "Configuration"

    if [[ -z "$GIT_USERNAME" ]]; then
        read -rp "GitHub username for GitOps: " GIT_USERNAME
    fi

    if [[ -z "$GIT_PASSWORD" ]]; then
        read -rsp "GitHub personal access token: " GIT_PASSWORD
        echo
    fi

    if [[ "$GRAFANA_PASSWORD" == "CHANGE_ME_GRAFANA_PASSWORD" ]]; then
        read -rsp "Grafana admin password: " GRAFANA_PASSWORD
        echo
    fi

    log "Configuration:"
    log "  Rancher:       ${RANCHER_HOSTNAME} (v${RANCHER_VERSION})"
    log "  Replicas:      ${RANCHER_REPLICAS}"
    log "  Git repo:      ${GIT_REPO_URL}"
    log "  Git branch:    ${GIT_BRANCH}"
    log "  Monitoring:    kube-prometheus-stack v${MONITORING_CHART_VERSION}"
    log "  StorageClass:  ${STORAGE_CLASS}"
    log "  Log file:      ${LOG_FILE}"

    echo
    read -rp "Continue with deployment? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "Deployment cancelled."
        exit 0
    fi
}

# ────────────────────────────────────────────────────────────────
# Step 1: Create Namespaces
# ────────────────────────────────────────────────────────────────

create_namespaces() {
    step "Step 1: Creating Namespaces"

    kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-system
  labels:
    app.kubernetes.io/name: rancher
    app.kubernetes.io/part-of: infrastructure
    cluster: mgmt
---
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-fleet-system
  labels:
    app.kubernetes.io/name: fleet
    app.kubernetes.io/part-of: infrastructure
    cluster: mgmt
---
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-monitoring-system
  labels:
    app.kubernetes.io/name: monitoring
    app.kubernetes.io/part-of: infrastructure
    cluster: mgmt
---
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-dashboards
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/part-of: monitoring
    cluster: mgmt
EOF

    success "Namespaces created"
}

# ────────────────────────────────────────────────────────────────
# Step 2: Install Rancher 2.14.0
# ────────────────────────────────────────────────────────────────

install_rancher() {
    step "Step 2: Installing Rancher ${RANCHER_VERSION}"

    # Add Helm repo
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo update

    # Check if already installed
    if helm --kube-context "$MGMT_CONTEXT" list -n cattle-system 2>/dev/null | grep -q rancher; then
        local current_ver
        current_ver=$(helm --kube-context "$MGMT_CONTEXT" list -n cattle-system -o json 2>/dev/null | jq -r '.[0].app_version // "unknown"')
        if [[ "$current_ver" == "$RANCHER_VERSION" ]]; then
            warn "Rancher ${RANCHER_VERSION} already installed. Skipping."
            return 0
        fi
        log "Upgrading Rancher from ${current_ver} to ${RANCHER_VERSION}"
        helm --kube-context "$MGMT_CONTEXT" upgrade rancher rancher-stable/rancher \
            --namespace cattle-system \
            --version "$RANCHER_VERSION" \
            --reuse-values \
            --wait --timeout 600s
    else
        log "Installing Rancher ${RANCHER_VERSION}..."
        helm --kube-context "$MGMT_CONTEXT" install rancher rancher-stable/rancher \
            --namespace cattle-system \
            --version "$RANCHER_VERSION" \
            --set hostname="$RANCHER_HOSTNAME" \
            --set replicas="$RANCHER_REPLICAS" \
            --set bootstrapPassword="$RANCHER_BOOTSTRAP_PASSWORD" \
            --set tls=external \
            --set ingress.enabled=true \
            --set ingress.ingressClassName=nginx \
            --set 'extraAnnotations.nginx\.ingress\.kubernetes\.io/ssl-redirect=true' \
            --set 'extraAnnotations.nginx\.ingress\.kubernetes\.io/proxy-body-size=0' \
            --set 'extraAnnotations.cert-manager\.io/cluster-issuer=letsencrypt-prod' \
            --set service.type=ClusterIP \
            --set resources.requests.cpu=250m \
            --set resources.requests.memory=512Mi \
            --set resources.limits.cpu=1 \
            --set resources.limits.memory=1Gi \
            --set noAntiAffinity=true \
            --set auditLevel=0 \
            --set debug=false \
            --set privateCA=false \
            --wait --timeout 600s
    fi

    # Wait for rollout
    log "Waiting for Rancher deployment to be ready..."
    kubectl --context "$MGMT_CONTEXT" rollout status deployment/rancher \
        -n cattle-system --timeout=300s

    # Verify pods
    local running_pods
    running_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-system \
        -l app=rancher --no-headers 2>/dev/null | grep -c Running || true)
    success "Rancher deployed: ${running_pods}/${RANCHER_REPLICAS} pods running"

    # Verify API
    local retries=0
    while [[ $retries -lt 30 ]]; do
        if curl -sk "https://${RANCHER_HOSTNAME}/ping" 2>/dev/null | grep -q pong; then
            success "Rancher API responding at https://${RANCHER_HOSTNAME}"
            break
        fi
        retries=$((retries + 1))
        sleep 5
    done

    if [[ $retries -ge 30 ]]; then
        warn "Rancher API not responding after 150s. Check ingress and DNS."
    fi
}

# ────────────────────────────────────────────────────────────────
# Step 3: Configure Fleet GitOps
# ────────────────────────────────────────────────────────────────

configure_fleet() {
    step "Step 3: Configuring Fleet GitOps"

    # Wait for Fleet controller
    log "Waiting for Fleet controller..."
    kubectl --context "$MGMT_CONTEXT" rollout status deployment/fleet-controller \
        -n cattle-fleet-system --timeout=120s 2>/dev/null || true

    local fleet_pods
    fleet_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-fleet-system \
        --no-headers 2>/dev/null | grep -c Running || true)
    success "Fleet controller running: ${fleet_pods} pods"

    # Create HTTP basic auth secret in fleet-local (for fleet-mgmt GitRepo)
    log "Creating Git HTTP basic auth secrets..."
    kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: git-http-basic-auth
  namespace: fleet-local
type: Opaque
stringData:
  username: "${GIT_USERNAME}"
  password: "${GIT_PASSWORD}"
---
apiVersion: v1
kind: Secret
metadata:
  name: git-http-basic-auth
  namespace: fleet-default
type: Opaque
stringData:
  username: "${GIT_USERNAME}"
  password: "${GIT_PASSWORD}"
EOF

    # Deploy mgmt-cluster GitRepo
    log "Deploying Fleet GitRepo for mgmt-cluster..."
    kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: fleet-mgmt
  namespace: fleet-local
  labels:
    app: mbtux-kubernetes
    environment: production
    cluster: mgmt
  annotations:
    description: "MBTUX Kubernetes - Management cluster FleetCD configuration"
spec:
  repo: ${GIT_REPO_URL}
  branch: ${GIT_BRANCH}
  pollingInterval: 60s
  insecureSkipTLSVerify: false
  clientSecretName: git-http-basic-auth
  correctDrift:
    enabled: true
    force: false
    keepFailHistory: true
  keepResources: false
  deleteNamespace: false
  paths:
    - infrastructure/rancher
    - infrastructure/cloudflared-mgmt
  targets:
    - name: mgmt-cluster
      clusterName: local
EOF

    success "Fleet GitRepo (mgmt) deployed"

    # Verify sync
    log "Waiting for initial GitRepo sync..."
    sleep 15
    local gitrepo_status
    gitrepo_status=$(kubectl --context "$MGMT_CONTEXT" get gitrepo -n fleet-local fleet-mgmt \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$gitrepo_status" == "True" ]]; then
        success "Fleet GitRepo (mgmt) synced successfully"
    else
        warn "Fleet GitRepo (mgmt) status: ${gitrepo_status}. Check 'kubectl get gitrepo -n fleet-local'"
    fi
}

# ────────────────────────────────────────────────────────────────
# Step 4: Install Monitoring Stack
# ────────────────────────────────────────────────────────────────

install_monitoring() {
    step "Step 4: Installing Monitoring Stack"

    # Add prometheus-community repo
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    # Check if already installed
    if helm --kube-context "$MGMT_CONTEXT" list -n cattle-monitoring-system 2>/dev/null | grep -q monitoring; then
        warn "Monitoring stack already installed. Skipping."
        return 0
    fi

    log "Installing kube-prometheus-stack v${MONITORING_CHART_VERSION}..."
    helm --kube-context "$MGMT_CONTEXT" install monitoring prometheus-community/kube-prometheus-stack \
        --namespace cattle-monitoring-system \
        --version "$MONITORING_CHART_VERSION" \
        --set prometheus.prometheusSpec.replicas=2 \
        --set prometheus.prometheusSpec.retention="$PROMETHEUS_RETENTION" \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="$PROMETHEUS_STORAGE" \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="$STORAGE_CLASS" \
        --set alertmanager.alertmanagerSpec.replicas=2 \
        --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage="$ALERTMANAGER_STORAGE" \
        --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName="$STORAGE_CLASS" \
        --set grafana.enabled=true \
        --set grafana.replicas=1 \
        --set grafana.adminPassword="$GRAFANA_PASSWORD" \
        --set grafana.ingress.enabled=true \
        --set grafana.ingress.ingressClassName=nginx \
        --set "grafana.ingress.hosts[0]=${GRAFANA_HOSTNAME}" \
        --set 'grafana.ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod' \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.size="$GRAFANA_STORAGE" \
        --set grafana.persistence.storageClassName="$STORAGE_CLASS" \
        --set nodeExporter.enabled=true \
        --set kubeStateMetrics.enabled=true \
        --wait --timeout 600s

    success "Monitoring stack installed"

    # Verify components
    local prom_pods alert_pods grafana_pods
    prom_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-monitoring-system \
        -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c Running || true)
    alert_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-monitoring-system \
        -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -c Running || true)
    grafana_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-monitoring-system \
        -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -c Running || true)

    success "Prometheus: ${prom_pods} pods | AlertManager: ${alert_pods} pods | Grafana: ${grafana_pods} pods"
}

# ────────────────────────────────────────────────────────────────
# Step 5: Register data-cluster
# ────────────────────────────────────────────────────────────────

register_data_cluster() {
    step "Step 5: Registering data-cluster"

    # Check if data-cluster context is available
    if ! kubectl --context "$DATA_CONTEXT" cluster-info &>/dev/null; then
        warn "data-cluster not reachable. Skipping registration."
        warn "Register via Rancher UI: Cluster Management -> Import Existing -> Generic"
        return 0
    fi

    # Check if already registered
    local existing
    existing=$(kubectl --context "$MGMT_CONTEXT" get clusters.management.cattle.io \
        data-cluster -o name 2>/dev/null || echo "")
    if [[ -n "$existing" ]]; then
        warn "data-cluster already registered. Skipping."
        return 0
    fi

    # Create registration token
    log "Creating cluster registration token..."
    local token_response
    token_response=$(curl -sk -u "admin:${RANCHER_BOOTSTRAP_PASSWORD}" \
        "https://${RANCHER_HOSTNAME}/v3/clusters/local?action=generateKubeconfig" \
        -H 'Content-Type: application/json' \
        -d '{}' 2>/dev/null || echo "{}")

    # Apply Fleet agent bundle
    log "Applying Fleet agent bundle to data-cluster..."
    kubectl --context "$MGMT_CONTEXT" apply -f infrastructure/rancher/cluster-data.yaml

    # Deploy data-cluster GitRepo
    log "Deploying Fleet GitRepo for data-cluster..."
    kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: fleet-data
  namespace: fleet-default
  labels:
    app: mbtux-kubernetes
    environment: production
    cluster: data
  annotations:
    description: "MBTUX Kubernetes - Data cluster FleetCD configuration"
spec:
  repo: ${GIT_REPO_URL}
  branch: ${GIT_BRANCH}
  pollingInterval: 60s
  insecureSkipTLSVerify: false
  clientSecretName: git-http-basic-auth
  correctDrift:
    enabled: true
    force: false
    keepFailHistory: true
  keepResources: false
  deleteNamespace: false
  paths:
    - infrastructure/cloudflared-data
  targets:
    - name: data-cluster
      clusterSelector:
        matchLabels:
          cluster: data
EOF

    success "data-cluster Fleet GitRepo deployed"

    # Verify registration
    sleep 10
    local cluster_state
    cluster_state=$(kubectl --context "$MGMT_CONTEXT" get cluster -n fleet-default data-cluster \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    log "data-cluster Fleet status: ${cluster_state}"
}

# ────────────────────────────────────────────────────────────────
# Step 6: Configure RBAC
# ────────────────────────────────────────────────────────────────

configure_rbac() {
    step "Step 6: Configuring RBAC"

    kubectl --context "$MGMT_CONTEXT" apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rancher-cluster-viewer
rules:
  - apiGroups: ["management.cattle.io"]
    resources: ["clusters"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["fleet.cattle.io"]
    resources: ["gitrepos", "bundles", "clusters"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["namespaces", "pods", "services"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rancher-cluster-admin
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rancher-fleet-manager
rules:
  - apiGroups: ["fleet.cattle.io"]
    resources: ["gitrepos", "bundles", "clusters", "clustergroups"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["fleet.cattle.io"]
    resources: ["gitrepos/status", "bundles/status", "clusters/status"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rancher-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rancher-cluster-admin
subjects:
  - kind: Group
    name: rancher-admins
    apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rancher-viewer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rancher-cluster-viewer
subjects:
  - kind: Group
    name: rancher-viewers
    apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rancher-fleet-manager-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rancher-fleet-manager
subjects:
  - kind: Group
    name: fleet-managers
    apiGroup: rbac.authorization.k8s.io
EOF

    success "RBAC configured"
}

# ────────────────────────────────────────────────────────────────
# Step 7: Deploy Backup CronJob
# ────────────────────────────────────────────────────────────────

deploy_backup() {
    step "Step 7: Deploying Backup CronJob"

    kubectl --context "$MGMT_CONTEXT" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rancher-backup
  namespace: cattle-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rancher-backup-role
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["resources.cattle.io"]
    resources: ["backups"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rancher-backup-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rancher-backup-role
subjects:
  - kind: ServiceAccount
    name: rancher-backup
    namespace: cattle-system
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rancher-backup
  namespace: cattle-system
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: rancher-backup
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: rancher/rancher-backup:v5.0.2
              command:
                - /bin/sh
                - -c
                - |
                  echo "Starting Rancher backup at $(date)"
                  rancher-backup create \
                    --filename="rancher-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
                  echo "Backup completed at $(date)"
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
EOF

    success "Backup CronJob deployed (daily at 02:00 UTC)"
}

# ────────────────────────────────────────────────────────────────
# Validation
# ────────────────────────────────────────────────────────────────

validate_deployment() {
    step "Post-Deployment Validation"

    local pass=0
    local fail=0
    local warn_count=0

    # Rancher pods
    local rancher_pods
    rancher_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-system \
        -l app=rancher --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "$rancher_pods" -ge 2 ]]; then
        success "Rancher: ${rancher_pods} pods running"
        pass=$((pass + 1))
    else
        error "Rancher: only ${rancher_pods} pods running (expected >=2)"
        fail=$((fail + 1))
    fi

    # Rancher API
    if curl -sk "https://${RANCHER_HOSTNAME}/ping" 2>/dev/null | grep -q pong; then
        success "Rancher API: responding"
        pass=$((pass + 1))
    else
        error "Rancher API: not responding"
        fail=$((fail + 1))
    fi

    # Rancher version
    local rancher_ver
    rancher_ver=$(curl -sk "https://${RANCHER_HOSTNAME}/v3/settings/server-version" 2>/dev/null | jq -r '.value // "unknown"')
    if [[ "$rancher_ver" == *"$RANCHER_VERSION"* ]]; then
        success "Rancher version: ${rancher_ver}"
        pass=$((pass + 1))
    else
        warn "Rancher version: ${rancher_ver} (expected ${RANCHER_VERSION})"
        warn_count=$((warn_count + 1))
    fi

    # Fleet controller
    local fleet_pods
    fleet_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-fleet-system \
        --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "$fleet_pods" -ge 1 ]]; then
        success "Fleet: ${fleet_pods} pods running"
        pass=$((pass + 1))
    else
        error "Fleet: no running pods"
        fail=$((fail + 1))
    fi

    # GitRepo sync
    local gitrepo_status
    gitrepo_status=$(kubectl --context "$MGMT_CONTEXT" get gitrepo -n fleet-local fleet-mgmt \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$gitrepo_status" == "True" ]]; then
        success "Fleet GitRepo (mgmt): synced"
        pass=$((pass + 1))
    else
        warn "Fleet GitRepo (mgmt): status=${gitrepo_status}"
        warn_count=$((warn_count + 1))
    fi

    # Prometheus
    local prom_pods
    prom_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-monitoring-system \
        -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "$prom_pods" -ge 1 ]]; then
        success "Prometheus: ${prom_pods} pods running"
        pass=$((pass + 1))
    else
        warn "Prometheus: not running"
        warn_count=$((warn_count + 1))
    fi

    # AlertManager
    local alert_pods
    alert_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-monitoring-system \
        -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "$alert_pods" -ge 1 ]]; then
        success "AlertManager: ${alert_pods} pods running"
        pass=$((pass + 1))
    else
        warn "AlertManager: not running"
        warn_count=$((warn_count + 1))
    fi

    # Grafana
    local grafana_pods
    grafana_pods=$(kubectl --context "$MGMT_CONTEXT" get pods -n cattle-monitoring-system \
        -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -c Running || true)
    if [[ "$grafana_pods" -ge 1 ]]; then
        success "Grafana: ${grafana_pods} pods running"
        pass=$((pass + 1))
    else
        warn "Grafana: not running"
        warn_count=$((warn_count + 1))
    fi

    # RBAC
    local roles
    roles=$(kubectl --context "$MGMT_CONTEXT" get clusterroles --no-headers 2>/dev/null | grep -c rancher || true)
    if [[ "$roles" -ge 1 ]]; then
        success "RBAC: ${roles} rancher cluster roles configured"
        pass=$((pass + 1))
    else
        warn "RBAC: no rancher cluster roles found"
        warn_count=$((warn_count + 1))
    fi

    # Backup CronJob
    if kubectl --context "$MGMT_CONTEXT" get cronjob -n cattle-system rancher-backup &>/dev/null; then
        success "Backup: CronJob scheduled"
        pass=$((pass + 1))
    else
        warn "Backup: CronJob not found"
        warn_count=$((warn_count + 1))
    fi

    echo
    log "Validation Summary: ${pass} passed, ${fail} failed, ${warn_count} warnings"
    echo
}

# ────────────────────────────────────────────────────────────────
# Post-deployment instructions
# ────────────────────────────────────────────────────────────────

post_deployment() {
    step "Post-Deployment Instructions"

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Rancher 2.14.0 Deployment Complete              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${CYAN}Access URLs:${NC}"
    echo -e "  Rancher UI:  https://${RANCHER_HOSTNAME}"
    echo -e "  Grafana:     https://${GRAFANA_HOSTNAME}"
    echo
    echo -e "${CYAN}Credentials:${NC}"
    echo -e "  Rancher:     admin / ${RANCHER_BOOTSTRAP_PASSWORD} (change after first login)"
    echo -e "  Grafana:     admin / ${GRAFANA_PASSWORD}"
    echo
    echo -e "${CYAN}Next Steps:${NC}"
    echo -e "  1. Log in to Rancher UI and change the admin password"
    echo -e "  2. Set the Rancher Server URL to https://${RANCHER_HOSTNAME}"
    echo -e "  3. Register data-cluster via Rancher UI:"
    echo -e "     Cluster Management -> Import Existing -> Generic"
    echo -e "  4. Verify Fleet GitRepo sync:"
    echo -e "     kubectl get gitrepo -A"
    echo -e "  5. Import Grafana dashboards (see docs/DEPLOYMENT_GUIDE.md)"
    echo
    echo -e "${CYAN}Verification Commands:${NC}"
    echo -e "  kubectl get pods -n cattle-system"
    echo -e "  kubectl get pods -n cattle-fleet-system"
    echo -e "  kubectl get pods -n cattle-monitoring-system"
    echo -e "  kubectl get gitrepo -A"
    echo -e "  curl -sk https://${RANCHER_HOSTNAME}/ping"
    echo
    echo -e "${CYAN}Documentation:${NC}"
    echo -e "  Deployment Guide:    docs/DEPLOYMENT_GUIDE.md"
    echo -e "  Troubleshooting:     docs/TROUBLESHOOTING.md"
    echo
    echo -e "${CYAN}Log file:${NC} ${LOG_FILE}"
    echo
}

# ────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────

main() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         Rancher 2.14.0 Automated Deployment Script          ║"
    echo "║         Fleet GitOps + Monitoring + RBAC + Backup           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log "Deployment started at $(date)"
    log "Log file: ${LOG_FILE}"

    preflight_checks
    prompt_values
    create_namespaces
    install_rancher
    configure_fleet
    install_monitoring
    register_data_cluster
    configure_rbac
    deploy_backup
    validate_deployment
    post_deployment

    log "Deployment completed at $(date)"
}

main "$@"
