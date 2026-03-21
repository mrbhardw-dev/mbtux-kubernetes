# mbtux-kubernetes

GitOps repository for the mbtux.com Kubernetes cluster managed by ArgoCD.

## Cluster Information


- **Kubernetes Version**: v1.31.14
- **Nodes**: 
  - asrock-master-01 (192.168.0.101)
  - asrock-worker-01 (192.168.0.102)
  - asrock-worker-02 (192.168.0.103)
- **Ingress**: Nginx via MetalLB (192.168.0.210)
- **Storage**: Longhorn (single replica)
- **Domain**: mbtux.com (Cloudflare managed)

## Repository Structure

```
mbtux-kubernetes/
├── bootstrap/                    # ArgoCD App of Apps
│   └── argocd-apps.yaml         # Root application definition
├── infrastructure/               # Infrastructure components
│   ├── longhorn/               # Storage
│   │   ├── helmrelease.yaml
│   │   ├── values.yaml
│   │   └── replica-fix-cronjob.yaml
│   ├── cert-manager/           # TLS certificates
│   │   ├── helmrelease.yaml
│   │   ├── values.yaml
│   │   └── clusterissuer.yaml
│   └── monitoring/             # Observability
│       ├── kube-state-metrics.yaml
│       ├── node-exporter.yaml
│       └── cadvisor.yaml
├── apps/                       # Applications
│   ├── nextcloud/
│   │   ├── argocd-app.yaml
│   │   └── values.yaml
│   └── codecombat/
│       └── ... (existing files)
└── cloudflared/               # Cloudflare tunnel (managed manually)
```

## Deployment Order

Infrastructure components must be deployed in the following order:

1. **Longhorn** - Storage provider (provides StorageClass)
2. **cert-manager** - TLS certificate management
3. **Monitoring** - kube-state-metrics, node-exporter, cAdvisor
4. **Nextcloud** - Application (depends on storage)

## Manual Components

The following are managed manually and NOT via ArgoCD:

- **ArgoCD** - Self-hosted in `argocd` namespace
- **MetalLB** - LoadBalancer in `metallb-system` namespace
- **Nginx Ingress Controller** - in `ingress-nginx` namespace
- **cloudflared** - Cloudflare tunnel in `cloudflared` namespace

## ArgoCD Access

- URL: https://argo.mbtux.com
- Username: admin
- Password: (set during initial setup)

## SSL/TLS

- **argo.mbtux.com** - TLS enabled via Let's Encrypt
- **longhorn.mbtux.com** - TLS enabled via Let's Encrypt  
- **nextcloud.mbtux.com** - HTTP only (Cloudflare Flexible SSL)

## Longhorn Replica Fix

Longhorn defaults to 2 replicas, but since we only have one node, a CronJob runs every 2 minutes to patch all volumes to use 1 replica:

```yaml
schedule: "*/2 * * * *"
```

## Nextcloud Configuration

- Storage: Longhorn (50Gi)
- Database: PostgreSQL (10Gi)
- Cache: Redis (8Gi)
- Probe timeouts: 600s initial delay to handle slow startup

## Troubleshooting

### Check ArgoCD sync status
```bash
kubectl get applications -n argocd
```

### Check Longhorn volumes
```bash
kubectl get volumes.longhorn.io -n longhorn-system
```

### Check Nextcloud pods
```bash
kubectl get pods -n nextcloud
```

### Manually patch Longhorn volumes (if needed)
```bash
for vol in $(kubectl get volumes -n longhorn-system -o name | awk -F/ '{print $2}'); do
  kubectl patch volume.longhorn.io $vol -n longhorn-system \
    --type merge -p '{"spec":{"numberOfReplicas":1}}'
done
```
