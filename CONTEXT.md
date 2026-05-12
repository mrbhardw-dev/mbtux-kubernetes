# mbtux-kubernetes Project Context

## Overview
This repository contains the complete GitOps configuration for the mbtux platform. ArgoCD runs on the **management cluster** and manages both the management cluster itself and the **data-prod** workload cluster.

## Cluster Architecture

### Management Cluster (192.168.0.201)
- **Purpose**: Runs ArgoCD, Traefik, cert-manager, Cloudflare tunnel, monitoring
- **ArgoCD**: Manages applications across all clusters via registered cluster secrets
- **Cloudflare Tunnel**: Routes `*.mgmt.mbtux.com` domains to mgmt cluster services
- **DNS**: `argocd-mgmt.mbtux.com`, `traefik-mgmt.mbtux.com`, `prometheus.mgmt.mbtux.com`

### Data Cluster - data-prod (192.168.0.211)
- **Purpose**: Production workload cluster
- **Services**: authentik, sure, outline, plus supporting infra
- **Cloudflare Tunnel**: Routes `*.mbtux.com` domains to data cluster services
- **DNS**: `authentik.mbtux.com`, `sure.mbtux.com`, `outline.mbtux.com`

## Directory Structure

```
mbtux-kubernetes/
├── CONTEXT.md
├── README.md
├── bin/
│   └── mbtux-kube-auth.sh             # kubeconfig auth helper
│
├── clusters/                          # Cluster manifests (kustomize bases)
│   ├── mgmt/                          # Management cluster manifests
│   │   ├── argocd/                    # ArgoCD infra (cert, ingress, oidc secret, network policy)
│   │   ├── cert-manager/              # ClusterIssuer, API token
│   │   ├── cloudflared/               # Cloudflare tunnel for mgmt cluster
│   │   ├── traefik/                   # Traefik Helm values + dashboard
│   │   ├── monitoring/                # Monitoring for mgmt cluster
│   │   └── clusters/                  # Cluster registration for ArgoCD multi-cluster
│   │
│   └── data-prod/                     # Data cluster manifests
│       ├── authentik/
│       ├── sure/
│       ├── outline/
│       ├── traefik/
│       ├── cloudflared/
│       ├── cert-manager/
│       └── monitoring/
│
├── gitops/                            # ArgoCD App-of-Apps definitions
│   ├── app-projects/                  # AppProject RBAC definitions
│   │   ├── mgmt-platform.yaml
│   │   ├── data-prod-infrastructure.yaml
│   │   └── data-prod-workloads.yaml
│   ├── mgmt-platform/                 # ArgoCD self-management apps
│   │   └── argocd/
│   │       ├── argocd-mgmt-helm.yaml  # ArgoCD Helm chart install
│   │       └── argocd-mgmt-infra.yaml # ArgoCD infra (cert, ingress, secret)
│   ├── mgmt-infrastructure/           # Mgmt cluster infrastructure apps
│   ├── data-infrastructure/           # Data cluster root apps
│   ├── root-app-mgmt-platform.yaml    # Bootstrap root apps
│   ├── root-app-mgmt-infrastructure.yaml
│   ├── root-app-data-infrastructure.yaml
│   └── root-app-data-workloads.yaml
│
├── mgmt-root/                         # Legacy bootstrap (kept for compatibility)
└── CONTEXT.md                         # This file
```

## ArgoCD Applications

### Management Cluster Apps (via mgmt ArgoCD)
| Application | Source Path | Deploys To |
|---|---|---|
| `argocd-management-helm` | Helm chart `argo-cd` | mgmt cluster (self-manage) |
| `mgmt-platform-infra` | `clusters/mgmt/argocd` | mgmt cluster |
| `traefik-management-helm` | Helm chart `traefik` | mgmt cluster |
| `traefik-mgmt.mbtux.com` | `clusters/mgmt/traefik` | mgmt cluster |
| `mgmt-infrastructure-cert-manager` | Helm chart `cert-manager` | mgmt cluster |
| `mgmt-infrastructure-cert-manager-resources` | `clusters/mgmt/cert-manager` | mgmt cluster |
| `mgmt-infrastructure-cloudflared` | `clusters/mgmt/cloudflared/manifests` | mgmt cluster |
| `mgmt-infrastructure-monitoring` | `clusters/mgmt/monitoring/manifests` | mgmt cluster |

### Data Cluster Apps (via mgmt ArgoCD → data-prod cluster)
| Application | Source Path | Deploys To |
|---|---|---|
| `authentik.mbtux.com` | `clusters/data-prod/authentik/manifests` | data-prod |
| `prod-infra-traefik` | Helm chart `traefik` | data-prod |
| `prod-infra-traefik-infra` | `clusters/data-prod/traefik` | data-prod |
| `prod-infra-cert-manager` | Helm chart `cert-manager` | data-prod |
| `prod-infra-cert-manager-resources` | `clusters/data-prod/cert-manager` | data-prod |
| `prod-infra-cloudflared` | `clusters/data-prod/cloudflared/manifests` | data-prod |
| `prod-infra-monitoring` | `clusters/data-prod/monitoring-data/manifests` | data-prod |
| `outline.mbtux.com` | `clusters/data-prod/outline/manifests` | data-prod |
| `sure.mbtux.com` | `clusters/data-prod/sure/manifests` | data-prod |

### AppProjects
- `mgmt-platform` - Platform components (ArgoCD itself)
- `mgmt-infrastructure` - Mgmt cluster infrastructure
- `data-prod-infrastructure` - Data cluster infrastructure (traefik, cert-manager, cloudflared, authentik, monitoring)
- `data-prod-workloads` - Workload applications (sure, outline)

## OIDC SSO

All services use Authentik as their OIDC provider:
- **Authentik URL**: `https://authentik.mbtux.com`
- **ArgoCD OIDC**: Redirect URI `https://argocd-mgmt.mbtux.com/auth/callback`
- **Provider slug**: `argocd` in Authentik
- **Client credentials**: Stored in `argocd-oidc-secret` in `argocd` namespace (mgmt cluster)

## Cloudflare Tunnels

Two independent tunnels:
- **Mgmt cluster tunnel** (`c6a8da22-...`): Routes `argocd-mgmt.mbtux.com`, `traefik-mgmt.mbtux.com`, `prometheus.mgmt.mbtux.com` → mgmt cluster Traefik
- **Data cluster tunnel** (`ae1dd134-...`): Routes `*.mbtux.com` (authentik, sure, outline) → data cluster Traefik

Both tunnels route to their respective cluster's Traefik service at `https://traefik.traefik.svc.cluster.local:443`. Ingress configuration per-host is managed via Traefik IngressRoute CRDs, not in the tunnel config.

## TLS Certificates

All services use Let's Encrypt certificates via cert-manager (DNS-01 challenge with Cloudflare):
- ClusterIssuer `letsencrypt-prod` on both clusters
- Each service has its own Certificate + Secret

## Multi-Cluster Management

The management cluster's ArgoCD manages the data cluster via:
- Registered cluster secret (ArgoCD cluster secret pointing to `https://192.168.0.211:6443`)
- Applications for data cluster services target the data cluster's API server, not `kubernetes.default.svc`

## Maintenance

### Adding a new application
1. Add manifest files in `clusters/data-prod/<service>/` (or `clusters/mgmt/` for mgmt services)
2. Create Application manifest in `gitops/data-infrastructure/` (or `gitops/mgmt-infrastructure/`)
3. Ensure AppProject allows the destination cluster
4. Commit and push

### Updating an application
- Update manifest files in the appropriate `clusters/` directory
- Sync via ArgoCD (auto-sync or manual depending on Application setting)

## Key Configuration Notes

- authentik-server: resources limits 1CPU/1Gi, HPA (CPU 70%, min 2, max 5)
- sure-worker: HPA managed (min 2, max 5), extensive `ignoreDifferences` in the Application
- cloudflared on data cluster uses 3 replicas, mgmt cluster uses 1 replica
- ArgoCD has `dex.enabled: false` — uses raw OIDC with Authentik directly

## ArgoCD RBAC

Configured in `gitops/mgmt-platform/argocd/argocd-mgmt-helm.yaml` under `server.rbacConfig`:
- `policy.default: role:admin` — all authenticated OIDC users get admin access
- OIDC user: `mritunjay.bhardwaj@mbtux.com`
- OIDC groups in Authentik: `authentik Admins`, `authentik Read-only`, `argocd-admins`, `argocd-developers`, `argocd-users`
- Issuer: `https://authentik.mbtux.com/application/o/argocd/`

## Session Context (2026-05-11)

### Completed (v1.8.0 — Observability Enhancement)

#### Previous session (v1.7.0-traefik-oidc-cleanup)
- Fixed data cluster Traefik dashboard 404 — removed `traefik-oidc-auth` plugin middleware + deleted orphaned manifests
- Stripped Traefik OIDC middleware from Grafana IngressRoute (Grafana uses native OIDC)
- Created `traefik-headers` Middleware in mgmt monitoring namespace for Prometheus ingress
- `data-prod/traefik` directory now identical to `mgmt/traefik`
- `https://traefik-data.mbtux.com/dashboard/` confirmed working

#### Migration to GitOps (aka "all pending items from v1.7.0")
Items 1-4 from the previous pending list are now DONE (committed across prior commits):
1. **Observability**: Prometheus + Grafana defined as ArgoCD apps (`gitops/mgmt-infrastructure/monitoring-kustomize.yaml`, `gitops/data-infrastructure/prod-infra-monitoring-kustomize.yaml`) with full manifests in `clusters/*/monitoring*/`
2. **Missing ArgoCD apps**: cert-manager, cloudflared, monitoring — all have Application manifests in `gitops/`
3. **Bootstrap root apps**: 4 root app manifests exist in `gitops/root-app-*.yaml`, bundled via `gitops/kustomization.yaml`
4. **argocd-management-helm**: Chart v7.5.2, image v3.3.9, `dex.enabled: false`, real OIDC credentials
5. **Placeholder secrets**: Still pending — `REPLACE_WITH_CLOUDFLARE_API_TOKEN` in cert-manager (both clusters)

#### This session — Observability dashboards & monitoring enhancements
- **Traefik scraping**: Added `traefik` Prometheus scrape job to both mgmt and data-prod clusters (`01-config.yaml`)
- **ArgoCD metrics**: Enabled metrics in ArgoCD Helm values (`argocd-mgmt-helm.yaml`) with ports 8082/8083/8084; added `argocd-server-metrics`, `argocd-metrics`, and `argocd-repo-server` scrape jobs to mgmt Prometheus
- **Traefik dashboard**: Added `grafana-traefik-dashboard` ConfigMap (`23-traefik-dashboard.yaml`) — official Grafana dashboard gnetId 17346
- **ArgoCD dashboard**: Added `grafana-argocd-dashboard` ConfigMap (`24-argocd-dashboard.yaml`) — community dashboard gnetId 14584
- **Alertmanager**: Set up Alertmanager on data-prod cluster (`13-alertmanager.yaml`) with Slack routing for warning/critical severity
- **Alerting rules**: Added Traefik (TraefikDown, TraefikHigh5xxRate) and ArgoCD (ArgoCDAppSyncFailed, ArgoCDAppMissing, ArgoCDAppDegraded) alerts to `12-alerts.yaml`
- **Cleanup**: Removed orphaned `clusters/mgmt/monitoring/values.yaml` (unused kube-prometheus-stack values) and `clusters/data-prod/monitoring-data/manifests/31-ingressclass.yaml` (nginx IngressClass on Traefik cluster)
- Updated both kustomization files to include new resources

#### Live fixes applied (not yet in ArgoCD/git)
- **Prometheus OOM crash**: Cleaned WAL (201 segments), increased memory 1Gi→4Gi, added `--storage.tsdb.retention.size=8GB` on data-prod
- **Grafana datasource**: Fixed data-cluster URL from `https://prometheus.data.mbtux.com` → `http://prometheus:9090`
- **CoreDNS**: Restored missing `prometheus.mgmt.mbtux.com` host entry + local DNS forwarder `192.168.0.10` on data-prod
- **Mgmt Prometheus TLS/Ingress**: Created missing `prometheus-mgmt-tls` Certificate + IngressRoute on mgmt cluster (were never synced)
- **Grafana OIDC RBAC**: Fixed role mapping from raw `groups` to JMESPath mapping Authentik groups (Admin/Editor/Viewer)
- **Grafana dashboards**: Mounted Traefik & ArgoCD dashboard ConfigMaps into Grafana deployment, added providers

### Pending
1. **Placeholder secrets**: `REPLACE_WITH_CLOUDFLARE_API_TOKEN` in cert-manager (both clusters)
2. **Alertmanager mgmt**: ✅ Added Alertmanager, alerting rules, and Prometheus alerting config to mgmt cluster
3. **Slack webhook**: Replace placeholder slack webhook URL in Alertmanager config with real URL
4. **Grafana external secrets**: Migrate grafana-password from plaintext to external-secrets/SOPS
5. **ArgoCD dashboard on mgmt**: Currently only on data-prod Grafana; mgmt has no Grafana at all (uses data-prod Grafana with cross-cluster datasource)
