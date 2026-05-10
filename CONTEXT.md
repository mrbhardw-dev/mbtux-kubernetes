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
- **Services**: authentik, sure, outline, coder, plus supporting infra
- **Cloudflare Tunnel**: Routes `*.mbtux.com` domains to data cluster services
- **DNS**: `authentik.mbtux.com`, `sure.mbtux.com`, `outline.mbtux.com`, `coder.mbtux.com`, etc.

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
│       ├── coder/
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
| `sure.mbtux.com` | `clusters/data-prod/sure/manifests` | data-prod |
| `outline.mbtux.com` | `clusters/data-prod/outline/manifests` | data-prod |
| `coder.mbtux.com` | `clusters/data-prod/coder/manifests` | data-prod |
| `prod-infra-traefik` | Helm chart `traefik` | data-prod |
| `prod-infra-traefik-infra` | `clusters/data-prod/traefik` | data-prod |
| `prod-infra-cert-manager` | Helm chart `cert-manager` | data-prod |
| `prod-infra-monitoring` | `clusters/data-prod/monitoring/manifests` | data-prod |

### AppProjects
- `mgmt-platform` - Platform components (ArgoCD itself)
- `mgmt-infrastructure` - Mgmt cluster infrastructure
- `data-prod-infrastructure` - Data cluster infrastructure (traefik, cert-manager, authentik, monitoring)
- `data-prod-workloads` - Workload applications (sure, outline, coder)

## OIDC SSO

All services use Authentik as their OIDC provider:
- **Authentik URL**: `https://authentik.mbtux.com`
- **ArgoCD OIDC**: Redirect URI `https://argocd-mgmt.mbtux.com/auth/callback`
- **Provider slug**: `argocd` in Authentik
- **Client credentials**: Stored in `argocd-oidc-secret` in `argocd` namespace (mgmt cluster)

## Cloudflare Tunnels

Two independent tunnels:
- **Mgmt cluster tunnel** (`c6a8da22-...`): Routes `argocd-mgmt.mbtux.com`, `traefik-mgmt.mbtux.com`, `prometheus.mgmt.mbtux.com` → mgmt cluster Traefik
- **Data cluster tunnel** (`ae1dd134-...`): Routes `*.mbtux.com` (authentik, sure, outline, coder) → data cluster Traefik

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

## Session Context (2026-05-10)

### Completed
- Fixed data cluster Traefik dashboard 404 — root cause was `traefik-oidc-auth` plugin not installed on data Traefik, so the dashboard IngressRoute's OIDC middleware blocked the route; removed middleware + deleted orphaned `traefik-oidc-auth.yaml` and `oidc-secret.yaml`
- Stripped Traefik OIDC middleware from Grafana IngressRoute — Grafana already uses native OIDC (`GF_AUTH_GENERIC_OAUTH_*`) via the `grafana-config` ConfigMap, the Traefik plugin layer was redundant
- Created `traefik-headers` Middleware in mgmt monitoring namespace to fix `middleware "monitoring-traefik-headers@kubernetescrd" does not exist` log warning on Prometheus ingress
- Fixed field name `hostedProxyHeaders` → removed (invalid field in Traefik Middleware spec)
- All changes applied directly to clusters (kubectl patch/apply) and committed as `v1.7.0-traefik-oidc-cleanup`
- `data-prod/traefik` directory now identical to `mgmt/traefik` (certificate.yaml, traefik-dashboard-ingressroute.yaml, values.yaml)
- `https://traefik-data.mbtux.com/dashboard/` confirmed working

### Pending (next session — observability focus)
1. **Observability**: Set up Prometheus + Grafana as managed ArgoCD apps, build dashboards, configure alerting
2. **Missing ArgoCD apps** (running on clusters but not managed by ArgoCD):
   - cert-manager (both clusters)
   - cloudflared (both clusters)
   - monitoring (both clusters)
   - coder (data cluster)
3. **Bootstrap root apps**: create the app-of-apps from `gitops/root-app-*.yaml`
4. **Update `argocd-management-helm`**: replace old inline values with new repo version (v3.3.9, dex disabled, etc.)
5. **Placeholder secrets**: `REPLACE_WITH_CLOUDFLARE_API_TOKEN` in cert-manager, coder OIDC placeholders
