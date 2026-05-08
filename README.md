# mbtux-kubernetes

GitOps configuration for the mbtux platform using ArgoCD on a management cluster to manage multiple application clusters.

## Architecture

### Clusters
- **Management Cluster**: Runs ArgoCD and platform services
- **Data Cluster (data-prod)**: Production workload cluster hosting sure, outline, authentik, coder

### Directory Structure
```
gitops/
├── app-projects/          # ArgoCD AppProject definitions
├── data-infrastructure/   # Data cluster Applications
│   ├── prod-infra-*.yaml  # Infrastructure (traefik, monitoring, cert-manager)
│   └── prod-apps-*.yaml   # Workload applications
├── mgmt-infrastructure/   # Management cluster Applications
└── root-app-*.yaml        # Root Applications managing child apps

production-infrastructure/
├── sure/manifests/        # Sure application (Kustomize)
├── outline/manifests/     # Outline application
├── authentik/manifests/   # Authentik IDP
└── coder/manifests/       # Coder development platform
```

## Applications

| Domain | Service | Namespace |
|--------|---------|-----------|
| sure.mbtux.com | Sure | sure |
| outline.mbtux.com | Outline | outline |
| authentik.mbtux.com | Authentik | authentik |
| coder.mbtux.com | Coder | coder |

## Setup

1. Install ArgoCD on management cluster
2. Configure cluster secrets in `management-infrastructure/clusters/manifests/`
3. Apply root applications: `kubectl apply -f gitops/kustomization.yaml`

## Secrets Management

**Critical**: Replace placeholder secrets before deploying:

1. `production-infrastructure/authentik/manifests/secret.yaml`:
   - Generate secure `AUTHENTIK_SECRET_KEY` (min 50 chars)
   ```bash
   head -c 50 /dev/urandom | base64
   ```

2. `production-infrastructure/authentik/manifests/postgresql.yaml`:
   - Update `POSTGRES_PASSWORD` from `authentik123` to secure password

3. `production-infrastructure/sure/manifests/02-secret.yaml`:
   - Update `postgres-password` and `smtp-password` from defaults
   - `SECRET_KEY_BASE` now loaded from this secret

4. `production-infrastructure/outline/manifests/02-secret.yaml`:
   - Update `postgres-password`, `smtp-password`, and `oidc-client-secret`

5. `production-infrastructure/coder/manifests/02-secret.yaml`:
   - Update `postgres-password` and OIDC client credentials

## Known Issues Fixed

1. **authentik**: Secret name mismatch (`authentik-secret` → `authentik`)
2. **authentik**: Missing database connection env vars in deployment
3. **authentik**: PostgreSQL/Redis missing PVCs and health probes
4. **authentik**: Outpost deployment not included in kustomization
5. **authentik**: Missing liveness/readiness probes in deployment
6. **authentik**: IngressRoute had redundant middleware configuration
7. **sure**: HPA/PDB not included in kustomization
8. **sure**: `SECRET_KEY_BASE` hardcoded - now loaded from secret
9. **outline**: HPA/PDB combined in single file, now included in kustomization