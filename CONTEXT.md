# mbtux-kubernetes Project Context

## Overview
This repository contains the complete GitOps configuration for the mbtux platform using ArgoCD on a management cluster to manage multiple application clusters (data-prod, etc.).

## Cluster Architecture

### Management Cluster
- **Purpose**: Runs ArgoCD and other platform services
- **ArgoCD**: Manages applications across all clusters
- **Location**: Management cluster (separate from data cluster)

### Data Cluster (data-prod)
- **Purpose**: Production workload cluster
- **Services hosted**: sure, outline, authentik
- **Namespace convention**: Each service gets its own namespace

## ArgoCD Applications

### Current Applications (by domain name)
- `sure.mbtux.com` → Service: sure (in `sure` namespace)
- `outline.mbtux.com` → Service: outline (in `outline` namespace)
- `authentik.mbtux.com` → Service: authentik (in `authentik` namespace)

### AppProjects
- `data-prod-infrastructure` - Infrastructure components (authentik, traefik, etc.)
- `data-prod-workloads` - Workload applications (sure, outline)
- `mgmt-platform` - Management platform components

### Important Notes
- All Applications use `https://kubernetes.default.svc` as the destination server (in-cluster ArgoCD API)
- The `data-prod-sure` Application has extensive `ignoreDifferences` configured because the sure-worker Deployment is managed by HPA and has many defaulted fields that differ between git and live state.

## Directory Structure

```
gitops/
├── app-projects/                    # AppProject definitions
│   ├── data-prod-infrastructure.yaml
│   ├── data-prod-workloads.yaml
│   └── mgmt-platform.yaml
├── data-infrastructure/             # Data cluster Applications
│   ├── sure.yaml
│   ├── outline.yaml
│   ├── authentik-kustomize.yaml
│   ├── prod-apps-sure.yaml         # Alternative sure app manifest
│   └── ...traefik, monitoring, etc.
└── mgmt-infrastructure/             # Management cluster Applications

production-infrastructure/           # Actual workload manifests
├── sure/manifests/                 # sure service Kustomize
│   ├── 20-sure.yaml               # Contains sure & sure-worker Deployments
│   └── ...
├── outline/manifests/              # outline service
├── authentik/manifests/            # authentik service
└── traefik/manifests/              # traefik ingress
```

## Key Configuration Details

### sure-worker Deployment
- **replicas**: Managed by HPA (min 2, max 5)
- **Resources**: CPU/Memory limits and requests set
- **Probes**: livenessProbe only (readinessProbe not used)
- **InitContainers**: wait-for-postgres, wait-for-redis
- **Termination**: Uses terminationMessagePath/Policy on containers and initContainers
- **PodSpec**: Uses default values (dnsPolicy=ClusterFirst, restartPolicy=Always, etc.)

### identik Deployment
- **Database**: Uses PostgreSQL with credentials from `authentik` secret
- **Redis**: Similarly configured
- **Service**: `authentik` service on ports 9000/9443
- **Ingress**: Traefik IngressRoute `authentik` terminates TLS and routes to `authentik:9000`

### Outline
- Simple deployment, destination server fixed to `kubernetes.default.svc`

## Important Environment Variables

### sure-worker
- `SECRET_KEY_BASE`: Fixed in manifest (should be moved to secret)
- Database & Redis config from ConfigMap `sure-config` and Secret `sure-secrets`
- OIDC config from ConfigMap `sure-auth`

### identik
- All config loaded via `envFrom: authentik` secret
- Contains: `AUTHENTIK_POSTGRESQL__*`, `AUTHENTIK_REDIS__*`, etc.

## Multi-Cluster Setup

The management cluster's ArgoCD manages applications on the data cluster using:
- `clusters.management.cattle.io` CRs (if using Rancher) OR
- ArgoCD cluster credentials stored in secrets/CRs

In this setup, Applications target the data cluster's API server via a Cluster (not hardcoded IP).

## Common Issues & Resolutions

### OutOfSync despite Healthy
- Usually caused by fields that are defaulted by Kubernetes (like HPA-set replicas)
- Solution: Add those paths to `ignoreDifferences` or exactly match the manifest to live state.

### Application not creating after rename
- ArgoCD does not rename Applications automatically when `metadata.name` changes.
- Must delete old Application and let ArgoCD create new one from manifest.

### Destination server errors
- Use `https://kubernetes.default.svc` for in-cluster ArgoCD
- Do not use hardcoded external API URLs.

## Maintenance

### Adding a new application
1. Create AppProject if needed (in `gitops/app-projects/`)
2. Create Application manifest in `gitops/data-infrastructure/` with proper project, source path, destination
3. Ensure destination namespace exists (or let it be created)
4. Commit and push - ArgoCD will sync automatically.

### Updating an application
- Update the manifest files in the appropriate directory.
- For changes to take effect, either:
  - Wait for automated sync (if enabled)
  - Or manually refresh the Application in ArgoCD UI/CLI.

## References
- Argo CD Docs: https://argo-cd.readtheds.io
- Identik Docs: https://docs.goauthentik.com
- Sure: ghcr.io/we-promise/sure