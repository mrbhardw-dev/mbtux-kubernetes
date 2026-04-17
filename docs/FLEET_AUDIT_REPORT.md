# Rancher Fleet Audit Report

## Executive Summary

This document captures the current state of Rancher Fleet in the `mbtux-kubernetes` cluster as part of the migration to Argo CD.

**Managed Cluster:** `data-cluster` (c-6mpn5) and `mgmt-cluster` (local)  
**Fleet Controller:** Running on mgmt-cluster (Rancher 2.14.0)  
**Git Repository:** https://github.com/mrbhardw-dev/mbtux-kubernetes.git  
**Branch:** `main`  
**Polling Interval:** 1 minute

---

## 1. Cluster Infrastructure

### 1.1 Managed Clusters

| Cluster ID | Name | Provider | Status | Labels |
|------------|------|----------|--------|---------|
| `c-6mpn5` | data-cluster | Bare Metal (Proxmox) | Active | `cluster: data` (implied) |
| `local` | mgmt-cluster | Bare Metal (Proxmox) | Active | N/A |

**Cluster Details** (from DEPLOYMENT_GUIDE.md):
- **mgmt-cluster**: 1 node (192.168.0.201), hosts Rancher, monitoring, cloudflared-mgmt
- **data-cluster**: 3 nodes (192.168.0.101-103), hosts applications and Argo CD (target of migration)

### 1.2 Cluster Groups (Fleet)

| Name | Label Selector | Target Clusters |
|------|----------------|-----------------|
| `fleet-local` | _Implicit_ (local cluster) | mgmt-cluster (`local`) |
| `fleet-default` | _Implicit_ (all non-local clusters) | data-cluster (`c-6mpn5`) |

Notes:
- Namespaces prefixed with `fleet-` determine which cluster group receives the resources.
- Resources in `fleet-local` namespace are deployed only to the local (mgmt) cluster.
- Resources in `fleet-default` are deployed to the data cluster.

---

## 2. GitRepo Inventory

### 2.1 GitRepos in `fleet-default` (target: data-cluster)

| Name | Repo URL | Branch | Paths | Target Cluster | Status | Resources |
|------|----------|--------|-------|----------------|--------|-----------|
| `authentik` | https://github.com/mrbhardw-dev/mbtux-kubernetes.git | main | `infrastructure/authentik` | `c-6mpn5` | Ready (1/1) | 19 resources |
| `cert-manager-data` | ... | main | `infrastructure/cert-manager` | `c-6mpn5` | **Not Ready** (0/1) | Missing: Namespace, ClusterIssuers |
| `cloudflared-data` | ... | main | `infrastructure/cloudflared-data` | `c-6mpn5` | **Not Ready** (0/1) | Missing Deployment |
| `nginx-ingress` | ... | main | `infrastructure/nginx-ingress` | `c-6mpn5` | **Not Ready** (0/1) | Missing IngressClass |
| `outline` | ... | main | `apps/outline` | `c-6mpn5` | Ready (1/1) | 14 resources |
| `sure` | ... | main | `apps/sure` | `c-6mpn5` | Ready (1/1) | 15 resources |

**Issues**:
- Several GitRepos show `Modified` condition due to manual changes (e.g., cert-manager ClusterIssuers, cloudflared deployment not owned by Fleet).
- These will require cleanup during migration.

### 2.2 GitRepos in `fleet-local` (target: mgmt-cluster)

| Name | Repo URL | Branch | Paths | Target Cluster | Status | Resources |
|------|----------|--------|-------|----------------|--------|-----------|
| `cloudflared-mgmt` | https://github.com/mrbhardw-dev/mbtux-kubernetes.git | main | `management/cloudflared-mgmt` | local | Ready (1/1) | 4 resources |
| `monitoring-mgmt` | ... | main | `management/monitoring-mgmt` | local | Ready (1/1) | 16 resources |
| `nginx-ingress` | ... | main | `infrastructure/nginx-ingress` | local | Ready (1/1) | 11 resources |

---

## 3. Bundle Summary

Bundles represent the rendered workload from a GitRepo. Key bundles:

| Namespace | Bundle Name | Resources Ready | Notes |
|-----------|-------------|------------------|-------|
| `fleet-default` | `authentik-infrastructure-authentik` | 1/1 | Healthy |
| `fleet-default` | `cert-manager-data-infrastructure-cert-manager` | 0/1 | Modified: missing ClusterIssuer & namespace |
| `fleet-default` | `cloudflared-data-infrastructure-cloudflared-data` | 0/1 | Modified: deployment not owned |
| `fleet-default` | `nginx-ingress-infrastructure-nginx-ingress` | 0/1 | Modified: IngressClass missing |
| `fleet-default` | `outline-apps-outline` | 1/1 | Healthy |
| `fleet-default` | `sure-apps-sure` | 1/1 | Healthy |
| `fleet-local` | `cloudflared-mgmt-management-cloudflared-mgmt` | 1/1 | Healthy |
| `fleet-local` | `monitoring-mgmt-management-monitoring-mgmt` | 1/1 | Healthy |
| `fleet-local` | `nginx-ingress-infrastructure-nginx-ingress` | 1/1 | Healthy |

---

## 4. Application Breakdown

### 4.1 Applications on data-cluster (fleet-default)

#### 4.1.1 authentik (SSO provider)
- **Namespace:** `authentik`
- **Pods:** authentik-server (1), authentik-worker (1), authentik-postgresql (StatefulSet)
- **Ingress:** `authentik.mbtux.com` (TLS via Let's Encrypt)
- **Storage:** PostgreSQL with 20Gi PVC
- **External dependencies:** None (self-contained)

#### 4.1.2 outline (collaboration platform)
- **Namespace:** `outline`
- **Components:** outline (web), outline-postgres, outline-redis
- **Ingress:** `outline.mbtux.com` (TLS via Let's Encrypt)
- **PVCs:** outline-postgres-pvc, outline-pvc (Postgres data), outline-redis-pvc

#### 4.1.3 sure (another app)
- **Namespace:** `sure`
- **Components:** sure (web), sure-postgres, sure-redis, sure-worker
- **Ingress:** `sure.mbtux.com` (TLS via Let's Encrypt)
- **PVCs:** sure-postgres-pvc, sure-pvc, sure-redis-pvc

#### 4.1.4 nginx-ingress
- **Namespace:** `ingress-nginx`
- **Controller:** nginx-ingress-controller (2 replicas)
- **Service:** LoadBalancer with MetalLB IP pool (192.168.0.211-214)
- **Notes:** IngressClass `nginx` exists but Fleet reports missing; likely due to ownership conflict.

#### 4.1.5 cloudflared-cloudflare tunnel
- **Namespace:** `cloudflared-data`
- **Components:** cloudflared deployment (tunnels to Cloudflare)
- **Secret:** `cloudflared-token` (Tunnel token)

#### 4.1.6 cert-manager
- **Namespace:** `cert-manager`
- **Components:** cert-manager controller, cainjector, webhook (currently manual installation)
- **Issuers:** letsencrypt-prod (DNS-01), letsencrypt-staging, vault-pki-int-issuer (broken)
- **Note:** Fleet currently errors because ClusterIssuers are missing (installed manually outside Fleet).

### 4.2 Applications on mgmt-cluster (fleet-local)

#### 4.2.1 monitoring-stack
- **Namespace:** `monitoring`
- **Components:** Prometheus (2 replicas), AlertManager (2), Grafana (1), node-exporter (DaemonSet), kube-state-metrics
- **Ingresses:** `grafana.mbtux.com`, `prometheus.data.mbtux.com`
- **Storage:** Prometheus PVC 50Gi, Grafana PVC 10Gi
- **Values:** monitoring-mgmt/values.yaml

#### 4.2.2 cloudflared-mgmt
- **Namespace:** `cloudflared-mgmt`
- **Components:** cloudflared deployment with separate tunnel token
- **Secret:** cloudflared-token

#### 4.2.3 nginx-ingress
- **Namespace:** `ingress-nginx` (shared with data cluster? Actually both clusters have separate ingress-nginx; but since they are separate clusters, they can have same namespace)
- Same as data but separate deployment on mgmt cluster.

---

## 5. Resource Inventory per GitRepo

| GitRepo | Namespaces | Workload Types | Total Resources | Healthy |
|---------|------------|----------------|-----------------|---------|
| authentik | authentik | Deployments, StatefulSet, Services, Ingress, Secrets, ConfigMaps, RBAC | 19 | ✅ |
| cert-manager-data | cert-manager | ClusterIssuer, Namespace, Secret | 4 (expecting) | ❌ Missing |
| cloudflared-data | cloudflared-data | Deployment, Namespace, Secret, ConfigMap | 3 (expecting) | ❌ Missing Deployment (not owned) |
| nginx-ingress (data) | ingress-nginx | Deployment, Service, ConfigMap, IngressClass, RBAC | 11 (expecting) | ❌ Missing IngressClass |
| outline | outline | Deployments, Services, PVCs, Ingress, Secrets, ConfigMaps | 14 | ✅ |
| sure | sure | Deployments, Services, PVCs, Ingress, Secrets, ConfigMaps | 15 | ✅ |
| cloudflared-mgmt | cloudflared-mgmt | Deployment, ConfigMap, Secret, Namespace | 4 | ✅ |
| monitoring-mgmt | monitoring | Deployments, DaemonSet, Services, PVCs, Ingresses, Secrets, ConfigMaps, RBAC | 16 | ✅ |
| nginx-ingress (mgmt) | ingress-nginx | Deployment, Service, ConfigMap, IngressClass, RBAC | 11 | ✅ |

---

## 6. Dependencies and Ordering

Some applications have dependencies:

1. **ingress-nginx** must be present before any HTTPS ingress resources can work (for both HTTP-01 Challenge and external traffic).
2. **cert-manager** must be ready before applications that request TLS certificates (authentik, outline, sure) can obtain certs.
3. **cloudflared** tunnels must be established to route external traffic from Cloudflare to the ingress.
4. **monitoring** depends on ingresses being available to expose Prometheus/Grafana.
5. **authentik** must be available before it can be used as OIDC provider for Argo CD (Phase 3).

Currently:
- nginx-ingress appears healthy on both clusters (though Fleet reports Modified for data cluster due to ownership issue).
- cert-manager is healthy after manual intervention; Fleet GitRepo shows Modified because ClusterIssuers not owned.
- cloudflared tunnels are healthy on both clusters.
- authentik, outline, sure are healthy on data cluster.
- monitoring is healthy on mgmt cluster.

---

## 7. Known Drift / Manual Changes

The following resources are **not owned by Fleet**, leading to `Modified` status:

1. **cert-manager data cluster**:
   - `ClusterIssuer` `letsencrypt-prod` and `letsencrypt-staging` exist but are not owned by Fleet GitRepo (created manually via cert-manager official install).
   - `Namespace` `cert-manager` exists but is not owned (Fleet expects to own it).

2. **cloudflared-data**:
   - `Deployment/cloudflared` in `cloudflared-data` namespace reported as not owned (Fleet wants to manage it; but it's present).

3. **nginx-ingress (data)**:
   - `IngressClass/nginx` reported as missing (Fleet expects it, but it exists and is owned by Helm release; maybe different name? There is an IngressClass resource named `nginx` from the Helm chart; but Fleet may not own it due to ownership by Helm). Actually there is an IngressClass `nginx` already; but the GitRepo reports missing means it's not present as a Fleet resource, possibly because the Helm chart created it but with different ownership.

These drifts should be resolved either by adopting the resources into Fleet (by adding proper labels/owner) or by recreating them via Fleet and removing manual changes.

---

## 8. RBAC and Service Accounts

- Rancher creates ClusterRoles for Fleet agent.
- Each application defines its own ServiceAccount (e.g., `authentik`, `sure`, `outline`).
- No cross-namespace service account sharing beyond defaults.

---

## 9. Secrets Management

- **Git auth**: Git repositories use HTTP basic auth with secret `auth-26sdb` (fleet-default) and `auth-phwh6` (fleet-local). These contain GitHub username and token.
- **Application secrets**: Each application (sure, outline, authentik) has its own `*-secrets` Secret with sensitive config.
- **Cloudflare tokens**: `cloudflared-token` secret in each cloudflared namespace contains tunnel token.
- **TLS certificates**: managed by cert-manager for apps; secrets `*-tls` hold certificates.
- **PostgreSQL passwords**: managed via separate secrets (e.g., `authentik-postgresql`, `sure-postgres`, etc.)

---

## 10. Network & Ingress

- **Ingress Controller**: nginx-ingress running on both clusters, with MetalLB (IP ranges: 192.168.0.211-214 on data, 192.168.0.210 on mgmt).
- **TLS**: Let's Encrypt certificates issued via cert-manager (HTTP-01) for `*.mbtux.com`.
- **Cloudflare Tunnel**: `cloudflared` agents connect to Cloudflare, routing `*.mbtux.com` to the nginx ingress.
- **Ingress Classes**: `nginx` (default for both clusters).

---

## 11. Migration Implications

### 11.1 Target Argo CD Topology

- **Management (Control) Cluster**: data cluster (c-6mpn5) will host Argo CD.
- **Managed Clusters**:
  - `data-cluster` (c-6mpn5) — Argo CD will manage applications **on itself** (local cluster).
  - `mgmt-cluster` (local) — Argo CD will manage applications **remotely** via cluster credentials.

### 11.2 Fleet Concept → Argo CD Mapping

| Fleet Concept | Argo CD Equivalent |
|---------------|-------------------|
| `GitRepo` | `Application` (single repo path) or `ApplicationSet` (multiple paths/clusters) |
| `Bundle` | Managed resources (outcome) |
| `Cluster` (target) | `Cluster` secret in Argo CD |
| Namespace-based targeting (`fleet-local` vs `fleet-default`) | `destination.namespace` + `destination.server` |
| Drift correction | `syncPolicy.autoSync` + `selfHeal: true` |

### 11.3 Migration Strategy per Application

| Application | Current Fleet GitRepo | Target Cluster | Migration Order | Notes |
|-------------|----------------------|----------------|-----------------|-------|
| cert-manager | cert-manager-data | data | **Phase 3-4** (prerequisite for TLS) | Already manually installed; will be adopted into Argo CD |
| nginx-ingress | nginx-ingress (both) | both | **First** (dependency) | Must be stable before app certs |
| cloudflared-data | cloudflared-data | data | Early | Needed for tunnel |
| authentik | authentik | data | Early (needed for OIDC) | |
| outline | outline | data | Mid | Independent |
| sure | sure | data | Mid | Independent |
| cloudflared-mgmt | cloudflared-mgmt | mgmt | Mid | |
| monitoring-mgmt | monitoring-mgmt | mgmt | Mid | |
| nginx-ingress (mgmt) | nginx-ingress (fleet-local) | mgmt | Already stable | |

---

## 12. Critical Path for Migration

1. **Prerequisites** (Phase 1):
   - Argo CD installed and accessible on data cluster (HTTPS).
   - PostgreSQL (external) and Redis running.
   - HTTPS ingress with cert-manager (pending DNS setup for `argocd.mbtux.com`).

2. **Cluster Registration** (Phase 5):
   - Register data cluster as "local" (default).
   - Register mgmt cluster as remote cluster (ServiceAccount + Bearer token).

3. **Infrastructure First** (to maintain availability):
   - Migrate ingress-nginx (ensure no downtime).
   - Migrate cert-manager (ensure TLS issuance continues).
   - Migrate cloudflared tunnels.

4. **Core Services**:
   - Migrate authentik (needed for SSO).
   - Migrate outline, sure.

5. **Monitoring**:
   - Migrate monitoring-mgmt to Argo CD.

6. **Cleanup**:
   - Disable Fleet GitRepos after Argo CD sync is stable (24h).
   - Remove Fleet resources.

---

## 13. Risks & Open Issues

| Risk | Impact | Mitigation |
|------|--------|------------|
| DNS not configured for `argocd.mbtux.com` | TLS cert can't be issued; HTTPS inaccessible | Create DNS A record pointing to ingress LB IPs before Phase 1 completion |
| Cloudflare API token missing for DNS-01 (if used) | Cannot issue wildcard certs | Use HTTP-01 for Argo CD; update ClusterIssuer accordingly |
| Fleet drift causes conflicts during dual-run | Resource differences may cause sync failures | Use `kubectl get` to compare, and disable Fleet sync before enabling Argo CD |
| Authentik connectivity from Argo CD OIDC | SSO fails if internal DNS/network blocks | Ensure Argo CD can reach `https://authentik.mbtux.com` |
| RBAC differences between Fleet and Argo CD | Permissions too permissive/restrictive | Review and replicate policies; test with user groups |
| Rolling back requires both systems in parallel | Complexity increases during dual-run | Keep Fleet enabled until Argo CD proven stable; have rollback steps ready |

---

## 14. Next Steps

1. Complete Phase 1: HTTPS for Argo CD (requires DNS).
2. Phase 2: Create Application manifests based on this audit.
3. Phase 3: Configure Authentik OIDC; test login.
4. Phase 5: Register mgmt cluster in Argo CD.
5. Phase 4: Begin gradual migration of Applications, starting with non-critical, then core, then monitoring.
6. Validate, monitor, and decommission Fleet.

---

**Audit Date:** 2026-04-17  
**Next Review:** After Phase 2 Manifest Generation
