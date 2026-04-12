# mbtux-kubernetes

GitOps repository for the mbtux.com Kubernetes cluster managed by ArgoCD and Fleet.

## Cluster Information

### Management Cluster (mgmt-cluster)
- **Kubernetes Version**: v1.31.14
- **Node**: 192.168.0.201
- **Rancher**: v2.14.0 (HA, 3 replicas)
- **Fleet**: v0.12.0 (GitOps controller)
- **Monitoring**: Prometheus + Grafana (kube-prometheus-stack)

### Data Cluster (data-cluster)
- **Kubernetes Version**: v1.31.14
- **Nodes**:
  - asrock-master-01 (192.168.0.101)
  - asrock-worker-01 (192.168.0.102)
  - asrock-worker-02 (192.168.0.103)

### Shared
- **Ingress**: Nginx via MetalLB (192.168.0.210)
- **Storage**: Proxmox ZFS CSI (StorageClass: proxmox-zfs)
- **Domain**: mbtux.com (Cloudflare managed)
- **Identity**: Zitadel (auth.mbtux.com)

## Architecture

```
                    mgmt-cluster
    ┌─────────────────────────────────────┐
    │  Rancher Dashboard (Control Plane)  │
    │  ├─ Fleet Management System         │
    │  ├─ Prometheus + Grafana (Monitor)  │
    │  ├─ RBAC & Policies                 │
    │  └─ Git Sync Controller             │
    └──────────────┬──────────────────────┘
                   │
        (Fleet GitOps, HTTP Basic Auth)
        (main branch sync, 60s polling)
                   │
    ┌──────────────▼──────────────────────┐
    │      data-cluster (Workload)        │
    │  ├─ Fleet Agent                     │
    │  ├─ Applications (synced)           │
    │  └─ Workload resources              │
    └─────────────────────────────────────┘
```

## Repository Structure

```
mbtux-kubernetes/
├── bootstrap/                          # ArgoCD App of Apps
│   ├── mgmt-cluster/
│   │   └── applications.yaml          # Cloudflared, Rancher
│   └── data-cluster/
│       └── applications.yaml          # ArgoCD, Cloudflared, Zitadel, Nginx
├── infrastructure/                     # Infrastructure components
│   ├── rancher/                       # Rancher 2.14.0 + Fleet
│   │   ├── fleet.yaml                 # Fleet Helm chart config
│   │   ├── values.yaml                # Rancher Helm values
│   │   ├── namespace.yaml
│   │   ├── cluster-mgmt.yaml          # mgmt-cluster registration
│   │   ├── cluster-data.yaml          # data-cluster registration
│   │   └── nodeport.yaml
│   ├── fleetCD-mgmt/                  # Fleet GitRepo for mgmt-cluster
│   │   └── config.yaml
│   ├── fleetCD-data/                  # Fleet GitRepo for data-cluster
│   │   └── config.yaml
│   ├── argocd/                        # ArgoCD for mgmt-cluster
│   ├── argocd-data/                   # ArgoCD for data-cluster
│   ├── nginx-ingress/                 # Nginx Ingress Controller
│   ├── cloudflared-mgmt/              # Cloudflare tunnel (mgmt)
│   ├── cloudflared-data/              # Cloudflare tunnel (data)
│   ├── proxmox-csi/                   # Proxmox ZFS CSI plugin
│   └── zitadel/                       # Zitadel identity provider
├── apps/                              # Applications
│   └── codecombat/                    # CodeCombat deployment
├── scripts/                           # Deployment & utility scripts
│   ├── deploy-rancher-fleet.sh        # Automated deployment
│   └── setup-mgmt-cluster-credentials.sh
├── docs/                              # Documentation
│   ├── DEPLOYMENT_GUIDE.md            # Comprehensive deployment guide
│   └── TROUBLESHOOTING.md             # Troubleshooting reference
└── management/                        # Reserved for management tools
```

## Quick Start

### Automated Deployment

```bash
chmod +x scripts/deploy-rancher-fleet.sh
./scripts/deploy-rancher-fleet.sh
```

### Manual Deployment

See [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) for step-by-step instructions.

## GitOps Flow

| Controller | Source | Target | Scope |
|-----------|--------|--------|-------|
| ArgoCD | bootstrap/mgmt-cluster/ | mgmt-cluster | Rancher, Cloudflared |
| ArgoCD | bootstrap/data-cluster/ | data-cluster | ArgoCD-data, Cloudflared, Zitadel, Nginx |
| Fleet | infrastructure/rancher/ | mgmt-cluster (local) | Rancher, Cloudflared-mgmt |
| Fleet | infrastructure/cloudflared-data/ | data-cluster | Cloudflared-data |

## Access

| Service | URL |
|---------|-----|
| Rancher UI | https://rancher.mbtux.com |
| Grafana | https://grafana.mbtux.com |
| ArgoCD (mgmt) | https://argo.mbtux.com |
| Zitadel | https://auth.mbtux.com |

## Verification

```bash
# Rancher
curl -sk https://rancher.mbtux.com/ping

# Fleet sync status
kubectl get gitrepo -A

# Monitoring
kubectl get pods -n cattle-monitoring-system

# All infrastructure
kubectl get pods -A | grep -E "cattle|rancher|fleet|monitoring"
```

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the full troubleshooting guide.

### Quick checks

```bash
# Rancher pods
kubectl get pods -n cattle-system

# Fleet controller
kubectl get pods -n cattle-fleet-system

# GitRepo sync status
kubectl get gitrepo -A

# Rancher logs
kubectl logs -n cattle-system -l app=rancher --tail=50

# Fleet logs
kubectl logs -n cattle-fleet-system -l app=fleet-controller --tail=50
```

## Manual Components

The following are managed manually (not via ArgoCD or Fleet):

- **MetalLB** - LoadBalancer in `metallb-system` namespace
- **cert-manager** - TLS certificate management in `cert-manager` namespace
- **RKE2** - Kubernetes distribution (installed directly on nodes)
