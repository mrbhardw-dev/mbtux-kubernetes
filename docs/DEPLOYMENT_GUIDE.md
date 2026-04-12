# Rancher 2.14.0 Deployment Guide

## Architecture Overview

```
                         mgmt-cluster (192.168.0.201)
    ┌──────────────────────────────────────────────────────────────┐
    │                  Rancher Dashboard (Control Plane)           │
    │                                                              │
    │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐  │
    │  │  Rancher Server  │  │  Fleet Manager   │  │  Monitoring │  │
    │  │  (3 replicas)    │  │  (GitOps Engine)  │  │  Stack      │  │
    │  │  HA mode         │  │  v0.12.x          │  │  Prometheus │  │
    │  └─────────────────┘  └────────┬────────┘  │  Grafana     │  │
    │                                 │           │  AlertManager│  │
    │  ┌─────────────────┐           │           └─────────────┘  │
    │  │  RBAC Policies   │           │                            │
    │  │  + HTTP Basic Auth│           │                            │
    │  └─────────────────┘           │                            │
    │                                 │                            │
    │  ┌─────────────────┐           │                            │
    │  │  Nginx Ingress   │           │                            │
    │  │  (ClusterIP)     │           │                            │
    │  │  MetalLB: .210   │           │                            │
    │  └─────────────────┘           │                            │
    └────────────────────────────────┼────────────────────────────┘
                                     │
              Fleet GitOps Sync      │  HTTP Basic Auth
              main branch, 60s poll   │  TLS via Let's Encrypt
                                     │
    ┌────────────────────────────────▼────────────────────────────┐
    │                  data-cluster (192.168.0.101-103)           │
    │                                                              │
    │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐  │
    │  │  Fleet Agent      │  │  Applications    │  │  Nginx      │  │
    │  │  (managed by      │  │  (synced from    │  │  Ingress    │  │
    │  │   mgmt-cluster)   │  │   Git repo)      │  │  Controller │  │
    │  └─────────────────┘  └─────────────────┘  └─────────────┘  │
    │                                                              │
    │  ┌─────────────────┐  ┌─────────────────┐                   │
    │  │  ArgoCD           │  │  Cloudflare      │                   │
    │  │  (additional      │  │  Tunnel          │                   │
    │  │   GitOps)         │  │  (ingress)       │                   │
    │  └─────────────────┘  └─────────────────┘                   │
    └──────────────────────────────────────────────────────────────┘

    Nodes:
    - asrock-master-01 (192.168.0.101) - control plane + worker
    - asrock-worker-01 (192.168.0.102) - worker
    - asrock-worker-02 (192.168.0.103) - worker
```

### Component Interaction Flow

```
Git Repository (GitHub)
    │
    ├──► Fleet GitRepo (mgmt) ──► mgmt-cluster
    │       ├── infrastructure/rancher/
    │       └── infrastructure/cloudflared-mgmt/
    │
    ├──► Fleet GitRepo (data) ──► data-cluster
    │       └── infrastructure/cloudflared-data/
    │
    └──► ArgoCD Applications
            ├── mgmt-cluster: cloudflared-mgmt, rancher
            └── data-cluster: argocd-data, cloudflared-data, zitadel, nginx-ingress

Rancher Server (mgmt-cluster)
    │
    ├──► Manages data-cluster via Fleet agent
    ├──► Provides UI at https://rancher.mbtux.com
    └──► Collects metrics via Prometheus/Grafana
```

---

## Pre-Deployment Requirements

### Infrastructure Requirements

| Resource | mgmt-cluster | data-cluster |
|----------|--------------|--------------|
| Nodes | 1 (192.168.0.201) | 3 (192.168.0.101-103) |
| CPU | 4 cores minimum | 4 cores per node |
| Memory | 8 GB minimum | 8 GB per node |
| Disk | 50 GB SSD | 50 GB SSD per node |
| Kubernetes | v1.31.14+ | v1.31.14+ |
| Network | MetalLB (192.168.0.210) | MetalLB or direct |

### Software Requirements

| Component | Version | Purpose |
|-----------|---------|---------|
| kubectl | v1.31.x+ | Cluster management |
| helm | v3.16.x+ | Chart deployment |
| Rancher CLI | v2.10.x+ | Optional, for advanced ops |
| git | 2.x+ | Repository management |
| curl | 7.x+ | API calls and health checks |
| jq | 1.6+ | JSON parsing |

### Verify Prerequisites

```bash
# Check kubectl
kubectl version --client
# Expected: v1.31.x

# Check helm
helm version --short
# Expected: v3.16.x+

# Check cluster connectivity (mgmt)
kubectl --context mgmt-cluster cluster-info

# Check cluster connectivity (data)
kubectl --context data-cluster cluster-info

# Verify nodes are Ready
kubectl --context mgmt-cluster get nodes
kubectl --context data-cluster get nodes

# Check MetalLB is running
kubectl --context mgmt-cluster get pods -n metallb-system
```

### Git Setup

```bash
# Clone the repository
git clone https://github.com/mrbhardw-dev/mbtux-kubernetes.git
cd mbtux-kubernetes

# Create HTTP basic auth secret for Fleet GitOps
# Replace with your GitHub credentials
kubectl --context mgmt-cluster create namespace cattle-fleet-system 2>/dev/null || true
kubectl --context mgmt-cluster -n cattle-fleet-system create secret generic git-http-basic-auth \
  --from-literal=username=YOUR_GITHUB_USERNAME \
  --from-literal=password=YOUR_GITHUB_TOKEN

# Verify secret exists
kubectl --context mgmt-cluster -n cattle-fleet-system get secret git-http-basic-auth
```

---

## Step 1: Management Cluster Preparation

### 1.1 Create Required Namespaces

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
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
```

### 1.2 Verify Nginx Ingress is Running

```bash
kubectl --context mgmt-cluster get pods -n ingress-nginx
kubectl --context mgmt-cluster get svc -n ingress-nginx
# Ensure the EXTERNAL-IP shows 192.168.0.210 (MetalLB)
```

### 1.3 Verify cert-manager is Running

```bash
kubectl --context mgmt-cluster get pods -n cert-manager
kubectl --context mgmt-cluster get clusterissuer
# Ensure letsencrypt-prod ClusterIssuer exists and is Ready
```

### 1.4 Verify MetalLB Configuration

```bash
kubectl --context mgmt-cluster get ipaddresspool -n metallb-system
kubectl --context mgmt-cluster get l2advertisement -n metallb-system
# Ensure IP pool includes 192.168.0.210
```

---

## Step 2: Rancher Installation on mgmt-cluster

### 2.1 Add Rancher Helm Repository

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
```

### 2.2 Install Rancher 2.14.0

```bash
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --version 2.14.0 \
  --set hostname=rancher.mbtux.com \
  --set replicas=3 \
  --set bootstrapPassword="nFtMpT^z!1B&la^WDiBd" \
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
  --set auditLevel=0 \
  --set debug=false \
  --set privateCA=false \
  --wait --timeout 600s
```

### 2.3 Verify Rancher Deployment

```bash
# Wait for all 3 replicas to be ready
kubectl --context mgmt-cluster rollout status deployment/rancher -n cattle-system --timeout=300s

# Check pod status
kubectl --context mgmt-cluster get pods -n cattle-system -l app=rancher

# Expected output:
# rancher-xxxxx-xxxxx   1/1   Running   0   2m
# rancher-xxxxx-xxxxx   1/1   Running   0   2m
# rancher-xxxxx-xxxxx   1/1   Running   0   2m

# Check ingress
kubectl --context mgmt-cluster get ingress -n cattle-system

# Verify Rancher API is accessible
curl -sk https://rancher.mbtux.com/ping
# Expected: pong
```

### 2.4 Retrieve Bootstrap Password

```bash
kubectl --context mgmt-cluster get secret --namespace cattle-system bootstrap-secret -o goop='{.data.bootstrapPassword}' | base64 --decode; echo
```

### 2.5 Initial Login

1. Open https://rancher.mbtux.com in your browser
2. Log in with the bootstrap password
3. Set a new admin password
4. Set the Rancher Server URL to `https://rancher.mbtux.com`
5. Accept the terms and conditions

---

## Step 3: Fleet Configuration for GitOps

### 3.1 Verify Fleet is Running

```bash
kubectl --context mgmt-cluster get pods -n cattle-fleet-system
# Expected: fleet-controller and gitjob pods running
```

### 3.2 Create HTTP Basic Auth Secret for Git

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: git-http-basic-auth
  namespace: cattle-fleet-system
type: Opaque
stringData:
  username: "YOUR_GITHUB_USERNAME"
  password: "YOUR_GITHUB_TOKEN"
EOF
```

### 3.3 Deploy Fleet GitRepo for mgmt-cluster

```bash
kubectl --context mgmt-cluster apply -f infrastructure/fleetCD-mgmt/config.yaml
```

Verify the GitRepo:

```bash
kubectl --context mgmt-cluster get gitrepo -n fleet-local
# Expected: fleet-mgmt should show Active status

# Check bundle status
kubectl --context mgmt-cluster get bundle -n fleet-local
```

### 3.4 Deploy Fleet GitRepo for data-cluster

After the data cluster is registered (Step 5):

```bash
kubectl --context mgmt-cluster apply -f infrastructure/fleetCD-data/config.yaml

kubectl --context mgmt-cluster get gitrepo -n fleet-default
# Expected: fleet-data should show Active status
```

### 3.5 Verify Fleet Drift Correction

```bash
# Check drift correction is enabled
kubectl --context mgmt-cluster get gitrepo -n fleet-local fleet-mgmt -o jsonpath='{.spec.correctDrift}'
# Expected: {"enabled":true,"force":false,"keepFailHistory":true}
```

---

## Step 4: Monitoring Stack (Prometheus + Grafana)

### 4.1 Add Monitoring Helm Repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 4.2 Install kube-prometheus-stack

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace cattle-monitoring-system \
  --version 66.2.2 \
  --set prometheus.prometheusSpec.replicas=2 \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=proxmox-zfs \
  --set alertmanager.alertmanagerSpec.replicas=2 \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=proxmox-zfs \
  --set grafana.enabled=true \
  --set grafana.replicas=1 \
  --set grafana.adminPassword="CHANGE_ME_GRAFANA_PASSWORD" \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=nginx \
  --set grafana.ingress.hosts[0]=grafana.mbtux.com \
  --set 'grafana.ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod' \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=10Gi \
  --set grafana.persistence.storageClassName=proxmox-zfs \
  --set nodeExporter.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --wait --timeout 600s
```

### 4.3 Verify Monitoring Stack

```bash
# Check Prometheus
kubectl --context mgmt-cluster get pods -n cattle-monitoring-system -l app.kubernetes.io/name=prometheus
# Expected: 2 prometheus pods running

# Check AlertManager
kubectl --context mgmt-cluster get pods -n cattle-monitoring-system -l app.kubernetes.io/name=alertmanager
# Expected: 2 alertmanager pods running

# Check Grafana
kubectl --context mgmt-cluster get pods -n cattle-monitoring-system -l app.kubernetes.io/name=grafana
# Expected: 1 grafana pod running

# Check Prometheus targets
kubectl --context mgmt-cluster port-forward -n cattle-monitoring-system svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
# Should show multiple active targets

# Check Grafana dashboards
curl -s -u admin:CHANGE_ME_GRAFANA_PASSWORD http://grafana.mbtux.com/api/search | jq length
# Should show pre-configured dashboards
```

### 4.4 Access Grafana

- URL: https://grafana.mbtux.com
- Username: `admin`
- Password: The password set during installation

### 4.5 Import Rancher Dashboards

```bash
# Import Rancher cluster dashboard (ID: 15515)
curl -s -u admin:CHANGE_ME_GRAFANA_PASSWORD \
  -H "Content-Type: application/json" \
  -d '{"dashboard":{"id":null,"uid":null,"name":"Rancher Cluster"},"inputs":[{"name":"DS_PROMETHEUS","type":"datasource","pluginId":"prometheus","value":"prometheus"}],"overwrite":true}' \
  https://grafana.mbtux.com/api/dashboards/import/15515
```

---

## Step 5: Data Cluster Registration

### 5.1 Retrieve Registration Command from Rancher UI

1. Open https://rancher.mbtux.com
2. Navigate to **Cluster Management**
3. Click **Import Existing**
4. Select **Generic** import method
5. Copy the registration command

### 5.2 Register data-cluster via CLI

```bash
# Get the registration token from Rancher API
RANCHER_URL="https://rancher.mbtux.com"
RANCHER_TOKEN=$(curl -sk -u "admin:YOUR_ADMIN_PASSWORD" \
  "${RANCHER_URL}/v3/clusterRegistrationTokens" \
  -H 'Content-Type: application/json' \
  -d '{"clusterId":"local"}' | jq -r '.insecureCommand')

# Run the registration command on data-cluster
# (Switch to data-cluster context)
kubectl --context data-cluster apply -f - <<'EOF'
# Paste the YAML from Rancher UI import page
# This includes the cattle-system namespace, deployment, and DaemonSet
EOF
```

### 5.3 Apply Fleet Agent Bundle to data-cluster

```bash
kubectl --context mgmt-cluster apply -f infrastructure/rancher/cluster-data.yaml
```

### 5.4 Verify data-cluster Registration

```bash
# On mgmt-cluster
kubectl --context mgmt-cluster get clusters.management.cattle.io
# Expected: data-cluster should appear with Active state

# Check Fleet cluster status
kubectl --context mgmt-cluster get cluster -n fleet-default
# Expected: data-cluster should show Active

# Check Fleet agent on data-cluster
kubectl --context data-cluster get pods -n cattle-fleet-system
# Expected: fleet-agent pod running

# Verify in Rancher UI
# Cluster Management -> data-cluster should show "Active"
```

---

## Step 6: HTTP Basic Auth Setup

### 6.1 Create Basic Auth Secret for Git Repository

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: git-http-basic-auth
  namespace: cattle-fleet-system
type: Opaque
stringData:
  username: "YOUR_GITHUB_USERNAME"
  password: "YOUR_GITHUB_PERSONAL_ACCESS_TOKEN"
---
apiVersion: v1
kind: Secret
metadata:
  name: git-http-basic-auth
  namespace: fleet-default
type: Opaque
stringData:
  username: "YOUR_GITHUB_USERNAME"
  password: "YOUR_GITHUB_PERSONAL_ACCESS_TOKEN"
EOF
```

### 6.2 Verify GitRepo Can Authenticate

```bash
# Check mgmt GitRepo
kubectl --context mgmt-cluster get gitrepo -n fleet-local fleet-mgmt -o jsonpath='{.status}'
# Should not show authentication errors

# Check data GitRepo
kubectl --context mgmt-cluster get gitrepo -n fleet-default fleet-data -o jsonpath='{.status}'
# Should not show authentication errors
```

### 6.3 Update Credentials (if needed)

```bash
# Delete and recreate the secret
kubectl --context mgmt-cluster delete secret git-http-basic-auth -n cattle-fleet-system
kubectl --context mgmt-cluster delete secret git-http-basic-auth -n fleet-default

# Recreate with new credentials
kubectl --context mgmt-cluster apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: git-http-basic-auth
  namespace: cattle-fleet-system
type: Opaque
stringData:
  username: "NEW_USERNAME"
  password: "NEW_TOKEN"
EOF
```

---

## Step 7: RBAC Configuration

### 7.1 Create Cluster Roles

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
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
EOF
```

### 7.2 Create Role Bindings

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
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
```

### 7.3 Create Namespace-Scoped RBAC

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cattle-system-manager
  namespace: cattle-system
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cattle-system-manager-binding
  namespace: cattle-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cattle-system-manager
subjects:
  - kind: Group
    name: cattle-admins
    apiGroup: rbac.authorization.k8s.io
EOF
```

### 7.4 Verify RBAC

```bash
kubectl --context mgmt-cluster get clusterroles | grep rancher
kubectl --context mgmt-cluster get clusterrolebindings | grep rancher

# Test permissions
kubectl --context mgmt-cluster auth can-i get gitrepos.fleet.cattle.io --as=system:serviceaccount:cattle-fleet-system:default
# Expected: yes
```

---

## Step 8: Alerting and Backup Procedures

### 8.1 Configure AlertManager

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-monitoring-kube-prometheus-alertmanager
  namespace: cattle-monitoring-system
type: Opaque
stringData:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 12h
      receiver: 'default-receiver'
      routes:
        - match:
            severity: critical
          receiver: 'critical-receiver'
          repeat_interval: 4h
        - match:
            severity: warning
          receiver: 'default-receiver'
          repeat_interval: 8h
    receivers:
      - name: 'default-receiver'
        # Configure webhook/email/slack here
        # Example webhook config:
        # webhook_configs:
        #   - url: 'https://your-webhook-url/alerts'
      - name: 'critical-receiver'
        # Configure PagerDuty/OpsGenie here
    inhibit_rules:
      - source_match:
          severity: 'critical'
        target_match:
          severity: 'warning'
        equal: ['alertname', 'cluster', 'service']
EOF
```

### 8.2 Create Backup CronJob

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
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
                    --filename="rancher-backup-$(date +%Y%m%d-%H%M%S).tar.gz" \
                    --storage-location=s3 \
                    --s3-bucketName=rancher-backups \
                    --s3-region=us-east-1
                  echo "Backup completed at $(date)"
              env:
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: access-key
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: secret-key
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
EOF
```

### 8.3 Create Backup ServiceAccount and RBAC

```bash
kubectl --context mgmt-cluster apply -f - <<'EOF'
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
  - apiGroups: ["catalog.cattle.io"]
    resources: ["apps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
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
EOF
```

### 8.4 Manual Backup Commands

```bash
# Manual etcd snapshot (on mgmt-cluster control plane)
ssh rancher@192.168.0.201 "sudo rke2 etcd-snapshot save --name manual-backup-$(date +%Y%m%d)"

# Backup Rancher configuration via API
RANCHER_TOKEN="token-xxxxx:YOUR_TOKEN"
curl -sk -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  "https://rancher.mbtux.com/v3/clusterBackups" \
  -H 'Content-Type: application/json' \
  -d '{"clusterId":"local","manual":true}'

# List existing backups
curl -sk -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  "https://rancher.mbtux.com/v3/clusterBackups" | jq '.data[].name'
```

---

## Production Hardening Checklist

### Security

- [ ] Bootstrap password changed from default
- [ ] Admin password is strong (16+ chars, mixed case, symbols)
- [ ] TLS enabled with valid certificates (Let's Encrypt or custom)
- [ ] HTTP basic auth tokens rotated regularly (every 90 days)
- [ ] RBAC policies applied (least privilege principle)
- [ ] Network policies configured for cattle-system namespace
- [ ] Pod security policies/standards enforced
- [ ] Secrets encrypted at rest (KMS provider)
- [ ] Audit logging enabled (auditLevel: 2 for production)
- [ ] Rancher API token expiration set

### Availability

- [ ] Rancher running with 3 replicas (HA mode)
- [ ] Pod anti-affinity rules configured for Rancher pods
- [ ] Persistent storage for Prometheus (50Gi+)
- [ ] Persistent storage for AlertManager (10Gi+)
- [ ] Persistent storage for Grafana (10Gi+)
- [ ] etcd snapshots scheduled (daily minimum)
- [ ] Backup CronJob running successfully
- [ ] Disaster recovery procedure tested

### Monitoring

- [ ] Prometheus scraping all targets
- [ ] Grafana dashboards imported and accessible
- [ ] AlertManager rules configured for critical alerts
- [ ] Node exporter running on all nodes
- [ ] kube-state-metrics running
- [ ] Log aggregation configured (optional: Loki)

### Network

- [ ] MetalLB IP pool configured correctly
- [ ] Nginx ingress with proper rate limiting
- [ ] DNS records pointing to MetalLB IP
- [ ] Cloudflare tunnels operational
- [ ] Firewall rules allowing required ports

### GitOps

- [ ] Fleet GitRepos syncing successfully
- [ ] Drift correction enabled and tested
- [ ] HTTP basic auth secret valid
- [ ] Git repository access verified from both clusters
- [ ] ArgoCD applications healthy

---

## Post-Deployment Verification Checklist

### Rancher Core

```bash
# 1. Rancher pods healthy
kubectl --context mgmt-cluster get pods -n cattle-system -l app=rancher
# All 3 pods should show 1/1 Running

# 2. Rancher API responding
curl -sk https://rancher.mbtux.com/ping
# Expected: pong

# 3. Rancher version correct
curl -sk https://rancher.mbtux.com/v3/settings/server-version | jq -r '.value'
# Expected: v2.14.0

# 4. Cluster management functional
kubectl --context mgmt-cluster get clusters.management.cattle.io
# Both clusters should be listed

# 5. Fleet controller healthy
kubectl --context mgmt-cluster get pods -n cattle-fleet-system
# fleet-controller and gitjob should be Running
```

### Fleet GitOps

```bash
# 6. GitRepo sync status
kubectl --context mgmt-cluster get gitrepo -A
# All repos should show Active with RecentSync

# 7. Bundle deployment status
kubectl --context mgmt-cluster get bundle -A
# All bundles should show Ready

# 8. Drift correction working
# Make a manual change to a managed resource
kubectl --context mgmt-cluster delete deployment rancher -n cattle-system --cascade=false
# Wait 60s and verify it's recreated
kubectl --context mgmt-cluster get deployment rancher -n cattle-system
```

### Monitoring Stack

```bash
# 9. Prometheus targets
kubectl --context mgmt-cluster get pods -n cattle-monitoring-system -l app.kubernetes.io/name=prometheus
# 2 Prometheus pods Running

# 10. Grafana accessible
curl -sk -u admin:YOUR_PASSWORD https://grafana.mbtux.com/api/health
# Expected: {"database":"ok"}

# 11. AlertManager functional
kubectl --context mgmt-cluster get pods -n cattle-monitoring-system -l app.kubernetes.io/name=alertmanager
# 2 AlertManager pods Running
```

### Data Cluster

```bash
# 12. data-cluster registered
kubectl --context mgmt-cluster get cluster -n fleet-default data-cluster
# Should show Active state

# 13. Fleet agent on data-cluster
kubectl --context data-cluster get pods -n cattle-fleet-system
# fleet-agent pod Running

# 14. Applications syncing
kubectl --context mgmt-cluster get gitrepo -n fleet-default fleet-data
# Should show Active with no errors
```

### Networking

```bash
# 15. Ingress routes working
kubectl --context mgmt-cluster get ingress -A
# All ingress resources should have ADDRESS set

# 16. DNS resolution
nslookup rancher.mbtux.com
# Should resolve to 192.168.0.210

# 17. TLS certificates valid
curl -svI https://rancher.mbtux.com 2>&1 | grep -i "expire\|subject"
# Certificate should be valid and not expiring soon
```
