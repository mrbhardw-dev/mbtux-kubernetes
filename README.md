# mbtux-kubernetes

GitOps configuration for the mbtux platform using ArgoCD on a management cluster to manage the data-prod workload cluster.

## Architecture

### Clusters
- **Management Cluster** (`192.168.0.201`): Runs ArgoCD, Traefik, cert-manager, Cloudflare tunnel
- **Data Cluster (data-prod)** (`192.168.0.211`): Production workloads (authentik, sure, outline, coder)

### Directory Structure
```
clusters/
├── mgmt/                   # Management cluster manifests
│   ├── argocd/             # ArgoCD infrastructure
│   ├── traefik/            # Traefik ingress controller
│   ├── cloudflared/        # Cloudflare tunnel (mgmt services)
│   ├── cert-manager/       # Let's Encrypt certificates
│   └── monitoring/         # Prometheus + Grafana
└── data-prod/              # Data cluster manifests
    ├── authentik/          # OIDC provider
    ├── sure/               # Sure application
    ├── outline/            # Outline wiki
    ├── coder/              # Coder development platform
    ├── traefik/            # Traefik ingress controller
    ├── cloudflared/        # Cloudflare tunnel (*.mbtux.com)
    ├── cert-manager/       # Let's Encrypt certificates
    └── monitoring/         # Prometheus + Grafana

gitops/                     # ArgoCD App-of-Apps definitions
├── app-projects/           # RBAC permissions
├── mgmt-platform/          # ArgoCD self-management
├── mgmt-infrastructure/    # Mgmt cluster apps
├── data-infrastructure/    # Data cluster apps
└── root-app-*.yaml         # Bootstrap applications
```

## Applications

| Domain | Service | Namespace | Cluster |
|--------|---------|-----------|---------|
| argocd-mgmt.mbtux.com | ArgoCD | argocd | mgmt |
| traefik-mgmt.mbtux.com | Traefik Dashboard | traefik | mgmt |
| prometheus.mgmt.mbtux.com | Prometheus | monitoring | mgmt |
| authentik.mbtux.com | Authentik | authentik | data-prod |
| sure.mbtux.com | Sure | sure | data-prod |
| outline.mbtux.com | Outline | outline | data-prod |
| coder.mbtux.com | Coder | coder | data-prod |

## OIDC SSO

All services authenticate via Authentik at `https://authentik.mbtux.com`:
- ArgoCD uses Authentik as OIDC provider (no Dex)
- Other services use Authentik's OIDC or Traefik forward auth

## Cloudflare Tunnels

Two tunnels manage external access:
- **Mgmt tunnel**: Routes `*.mgmt.mbtux.com` to mgmt cluster
- **Data tunnel**: Routes `*.mbtux.com` to data cluster

## Setup

1. Install ArgoCD on management cluster
2. Register data cluster in ArgoCD (cluster secret)
3. Configure Cloudflare tunnels in Zero Trust dashboard
4. Apply root applications: `kubectl apply -f gitops/kustomization.yaml`

## Secrets Management

Replace placeholder secrets before deploying:

1. `clusters/data-prod/authentik/manifests/secret.yaml`: Generate `AUTHENTIK_SECRET_KEY`
2. `clusters/data-prod/sure/manifests/02-secret.yaml`: Update postgres/smtp passwords
3. `clusters/data-prod/outline/manifests/02-secret.yaml`: Update passwords
4. `clusters/data-prod/coder/manifests/02-secret.yaml`: Update passwords
5. `clusters/mgmt/cert-manager/cloudflare-api-token.yaml`: Add real API token
6. `clusters/data-prod/cert-manager/cloudflare-api-token.yaml`: Add real API token
