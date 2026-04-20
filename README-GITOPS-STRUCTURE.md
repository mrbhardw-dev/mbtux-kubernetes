# GitOps Repository Structure

## Recommended Tree

```
mbtux-kubernetes/
├── clusters/
│   ├── data/                     # Data Cluster GitOps
│   │   ├── argocd-applications/   # ArgoCD Application manifests
│   │   │   ├── authentik.yaml
│   │   │   ├── outline.yaml
│   │   │   ├── sure.yaml
│   │   │   └── monitoring.yaml
│   │   └── values/                # Cluster-specific values overrides
│   │       ├── authentik-values.yaml
│   │       ├── outline-values.yaml
│   │       └── monitoring-values.yaml
│   │
│   └── management/               # Management Cluster GitOps
│       ├── argocd-applications/ # ArgoCD Application manifests
│       │   ├── argocd.yaml
│       │   ├── devtron.yaml
│       │   ├── monitoring.yaml
│       │   └── cloudflared.yaml
│       └── values/
│           ├── argocd-values.yaml
│           ├── devtron-values.yaml
│           └── monitoring-values.yaml
│
├── apps/                         # Shared applications
│   ├── authentik/
│   ├── outline/
│   ├── sure/
│   ├── monitoring/
│   │   ├── Chart.yaml
│   │   ├── values.yaml          # Base values (empty)
│   │   ├── values-data.yaml   # Data cluster overrides
│   │   └── values-mgmt.yaml  # Management cluster overrides
│   ├── cloudflared/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── values-data.yaml
│   │   └── values-mgmt.yaml
│   ├── argocd/
│   ├── devtron/
│   └── nginx-ingress/
│
└── scripts/
    ├── bootstrap-data-cluster.sh
    └── bootstrap-management-cluster.sh
```

## ArgoCD Application Examples

### Data Cluster (`clusters/data/argocd-applications/outline.yaml`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: outline
  namespace: argocd
spec:
  project: data
  source:
    repoURL: https://github.com/mrbhardw-dev/mbtux-kubernetes.git
    targetRevision: main
    path: apps/outline
  destination:
    server: https://192.168.0.211:6443  # Data cluster
    namespace: outline
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

### Management Cluster (`clusters/management/argocd-applications/monitoring.yaml`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  project: management
  source:
    repoURL: https://github.com/mrbhardw-dev/mbtux-kubernetes.git
    targetRevision: main
    path: apps/monitoring
    helm:
      valueFiles:
        - values-mgmt.yaml  # Management-specific values
  destination:
    server: https://kubernetes.default.svc  # Management cluster
    namespace: monitoring
```

## Devtron Mapping

| Devtron Concept    | GitOps Structure                    |
|------------------|-------------------------------------|
| Project          | `clusters/{cluster}/` folder         |
| Environment      | Separate project's environments       |
| App              | `apps/{app}/` or folder values     |
| Cluster          | `destination.server` in ArgoCD App  |

### Devtron Environment Setup
1. Create Projects: `data`, `management`
2. Create Environments:
   - `data-cluster` → maps to `clusters/data/`
   - `mgmt-cluster` → maps to `clusters/management/`
3. Link helm charts from `apps/{app}/values-{env}.yaml`

## Monitoring Separation

### Data Cluster: Prometheus only
- `apps/monitoring/values-data.yaml`:
```yaml
prometheus:
  enabled: true
grafana:
  enabled: false
alertmanager:
  enabled: false
```

### Management Cluster: Prometheus + Grafana
- `apps/monitoring/values-mgmt.yaml`:
```yaml
prometheus:
  enabled: true
grafana:
  enabled: true
alertmanager:
  enabled: true
```

## Migration Commands

```bash
# Step 1: Create new structure
mkdir -p clusters/data/argocd-applications clusters/data/values
mkdir -p clusters/management/argocd-applications clusters/management/values

# Step 2: Move ArgoCD applications
mv management/cloudflared-mgmt/manifests/argocd-application.yaml clusters/management/argocd-applications/
mv infrastructure/cloudflared-data/manifests/argocd-application.yaml clusters/data/argocd-applications/
mv infrastructure/monitoring-data/manifests/argocd-application.yaml clusters/data/argocd-applications/
# ... etc

# Step 3: Update paths in ArgoCD Application manifests
```