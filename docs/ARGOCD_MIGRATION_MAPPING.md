# Fleet → Argo CD Migration Mapping

## Overview

This document maps Rancher Fleet concepts, resources, and configurations to their Argo CD equivalents. It serves as a reference during the migration from Fleet to Argo CD.

---

## 1. Conceptual Mapping

| Fleet Concept | Argo CD Equivalent | Notes |
|---------------|-------------------|-------|
| `GitRepo` | `Application` or `ApplicationSet` | A GitRepo syncs a directory; Argo CD Application does the same with more options |
| `Bundle` | Application's deployed resources (manifested state) | Not a CRD; just the set of resources |
| `Cluster` (Fleet cluster registration) | `Cluster` (Argo CD cluster secret) | Both represent a target Kubernetes cluster |
| `ClusterGroup` | `AppProject` + cluster selectors in ApplicationSet | Fleet's cluster groups are implicit by namespace; Argo CD uses explicit cluster registration |
| Namespace-based targeting (`fleet-local`, `fleet-default`) | `destination.namespace` + `destination.server` | Direct mapping |
| Drift correction (`correctDrift`) | `syncPolicy.autoSync` + `selfHeal: true` | Argo CD automatically corrects drift |
| Git polling (interval) | Interval-based reconciliation (default 3m) or webhooks | Argo CD polls by default; can use webhooks |
| `forceSync` annotation | `argocd app sync` or `kubectl delete` to force | Manual equivalent |
| Bundle health assessment | Application health logic (built-in) | Argo CD has built-in health checks for common resources |

---

## 2. Resource Mapping

### 2.1 GitRepo Types → Argo CD Source

| Fleet Path Type | Argo CD Source `type` | Example |
|-----------------|----------------------|---------|
| Kustomize directory | `Directory` (Kustomize) | `spec.source.path: "apps/sure"` |
| Helm chart in Git (with `values.yaml`) | `Helm` | `spec.source.helm.valueFiles: ["values.yaml"]` |
| Plain Kubernetes YAMLs | `Directory` (merged) | N/A |

**Important**: In the current repository, deployment methods vary:
- **Kustomize only**: `infrastructure/cert-manager`, `infrastructure/cloudflared-data`, `infrastructure/cloudflared-mgmt`, `management/cloudflared-mgmt`, `apps/outline`, `apps/sure` (these have `kustomize.dir` and no Helm chart in the path).
- **Helm + Kustomize combo ( ingress only)**:
  - `nginx-ingress`: uses Helm chart from repo, values from `manifests/values.yaml`. The `manifests` directory contains only namespace and values; the chart templates come from external chart.
  - `authentik`: uses Helm for main chart + Kustomize for additional ingress resource.

### 2.2 Translation Strategy

For each GitRepo we will create one or more Argo CD Applications:

- **Pure Kustomize repos** → Single Application with `source.type: Directory`, `source.path: <repo-path>`, `destination.namespace: <namespace>`, `destination.server: <cluster URL>`.
- **Helm-based repos** → Application with `source.type: Helm`, specifying `chart`, `repo`, `targetRevision` (branch), and `valueFiles`. For repos that also have extra resources (like authentik's ingress), we may split:
  - Helm Application for the Helm chart (releases into `authentik` namespace).
  - Kustomize Application for the extra ingress (if not part of chart). Alternatively, combine using `helm` and `kustomize` in one App via `spec.source.directory` and `spec.source.helm`? Argo CD doesn't support mixing in a single Application. The recommended pattern is to either include the extra resources in the Helm chart via custom templates or use an Application of type `Kustomize` that references the chart via a HelmChart resource (Argo CD supports `helm` as a native type but you can also use ` HelmChart` CRD? Not needed). Simpler: use Helm chart for all resources if possible, or use a Kustomize overlay that includes the Helm chart via `helmCharts` in kustomization.yaml. However, the repo currently does not have a Kustomize that bundles Helm. So we can create Kustomize overlays that include Helm charts, but that requires changes to the repo.

Given migration constraints, we will create separate Applications:
- One Helm `Application` for the main chart (e.g., `authentik`).
- One `Application` (Kustomize) for namespace-scoped additional resources (ingress, etc.) that points to the same Git repo but different path (`infrastructure/authentik/manifests`). The namespace must match.

Alternatively, we can let the Helm chart handle ingress (if it supports it). But the current repo uses custom ingress; we'll keep as is.

### Mapping Table per Application

| Application (Proposed Name) | Source Git Repo | Path in Repo | Method | Destination Cluster | Destination Namespace |
|----------------------------|-----------------|--------------|--------|----------------------|-----------------------|
| `argocd-app-authentik` | mbtux-kubernetes | `infrastructure/authentik` | Helm + Kustomize split | data (c-6mpn5) | authentik |
| `argocd-app-authentik-ingress` | mbtux-kubernetes | `infrastructure/authentik/manifests` | Directory | data | authentik |
| `argocd-app-cert-manager` | mbtux-kubernetes | `infrastructure/cert-manager` | Directory (ClusterIssuer, Secret) | data | cert-manager |
| `argocd-app-cloudflared-data` | mbtux-kubernetes | `infrastructure/cloudflared-data` | Directory | data | cloudflared-data |
| `argocd-app-nginx-ingress-data` | mbtux-kubernetes | `infrastructure/nginx-ingress` | Helm | data | ingress-nginx |
| `argocd-app-outline` | mbtux-kubernetes | `apps/outline` | Directory | data | outline |
| `argocd-app-sure` | mbtux-kubernetes | `apps/sure` | Directory | data | sure |
| `argocd-app-cloudflared-mgmt` | mbtux-kubernetes | `management/cloudflared-mgmt` | Directory | mgmt | cloudflared-mgmt |
| `argocd-app-monitoring-mgmt` | mbtux-kubernetes | `management/monitoring-mgmt` | Directory | mgmt | monitoring |
| `argocd-app-nginx-ingress-mgmt` | mbtux-kubernetes | `infrastructure/nginx-ingress` | Helm | mgmt | ingress-nginx |

**Note**: The nginx-ingress repo path is same for both clusters, but the Application needs to select the appropriate cluster via `destination.server`. The Helm values are the same across clusters? Possibly some values differ (like replica counts)? The Helm values file may need overlays if cluster-specific values differ. The existing `infrastructure/nginx-ingress/manifests/values.yaml` is general; it might already be cluster-agnostic. If differences exist (e.g., number of replicas, load balancer IPs), we'll need to use Kustomize overlays or multiple value files. According to the values file, replica count is 2, autoscaling is on; should be fine for both clusters. The service type is LoadBalancer; MetalLB will allocate IPs per cluster.

If cluster-specific values are needed, we could use an ApplicationSet with generator `cluster` to produce per-cluster apps with different values. For simplicity now, we can deploy same values to both clusters; later we can adjust.

---

## 3. Sync Policy Mapping

| Fleet Policy | Argo CD Equivalent |
|--------------|--------------------|
| `pollingInterval: 1m0s` | Argo CD default: 3 minutes; can set `resource.customizations`? Actually there is no per-app poll interval config; it's global `--resource-exclude`? Argo CD uses informers and requeue. For Git polling, Argo CD uses a `timeout` and `interval` is fixed (by `--revision-history-limit`?). Wait: Argo CD doesn't poll; it uses `argocd-application-controller` which watches Git via cache? Actually Argo CD polls Git repos at a default interval of 3 minutes, configurable globally via `--repo-server` flag? There's a `--git-poll-interval` in repo server. We cannot set per-app interval; but it's okay. |
| `correctDrift: true` | `spec.syncPolicy.autoSync: { prune: true, selfHeal: true }` |
| `forceSyncGeneration` | Manual `argocd app sync` or `kubectl patch` to trigger | Not needed |
| `targets.clusterName` | `spec.destination.server` (URL) + `namespace` | Exact mapping |

---

## 4. Health & Status Checks

- Fleet's `bundle.status.conditions` ready check maps to Argo CD's `Application.status.health.status` (Healthy, Degraded, Progressing, etc).
- Resource-level health in Argo CD is built-in and more detailed.

---

## 5. Authentication / RBAC

- Fleet uses Rancher's RBAC; Argo CD uses its own RBAC.
- We'll replace Rancher auth with Authentik OIDC (Phase 3).
- Must create Argo CD `AppProject` and `Policy` to restrict access per group.

---

## 6. Migration Phases Alignment

| Migrated By | Deliverable |
|-------------|-------------|
| **Phase 1** | Argo CD deployed (completed Phase 1 items) |
| **Phase 2** | Audit report (this doc) + Application manifests (next) |
| **Phase 3** | Authentik OIDC configuration + RBAC policies |
| **Phase 4** | Application syncs with dual-run; validation |
| **Phase 5** | Multi-cluster registration + final cutover |

---

## 7. Pre-Migration Validation Checklist

For each Fleet application, verify:

- [ ] All pods are Running/Ready.
- [ ] No pending upgrades or errors.
- [ ] Ingress routes are functioning (curl works).
- [ ] Secrets are present and not expired.
- [ ] PVCs bound and healthy.
- [ ] No pending certificate renewals (check cert-manager).
- [ ] Backup of current state (Git commit, manifest exports via `kubectl get all -o yaml`).

---

## 8. Application Migration Steps (per app)

1. **Freeze Fleet** (optional): Disable GitRepo (`kubectl annotate gitrepo <name> fleet.cattle.io/disable-sync=""`) to prevent drift during migration.
2. **Create Argo CD Application** with same source/destination.
3. **Dry-run sync**: `argocd app wait <name> --sync-operation` or `kubectl apply --dry-run`.
4. **Initial sync**: `argocd app sync <name>`.
5. **Health check**: Verify all resources become Healthy.
6. **Functional test**: Access the application via its URL.
7. **Monitor** for 24-48hs.
8. **Disable Fleet GitRepo** (set to `inactive` or delete).
9. **Delete Fleet resources** (optional, after confirmation).

---

## 9. Rollback Plan

If an application fails after migration:

- **Step 1**: Pause the Argo CD Application (`argocd app pause <name>` or `spec.syncPolicy.automated: null`).
- **Step 2**: Re-enable Fleet GitRepo (remove disable annotation).
- **Step 3**: Ensure Fleet sync restores the previous state.
- **Step 4**: Investigate the issue, adjust manifest, retry.
- **Step 5**: Document root cause.

Keep Fleet resources until Argo CD proven stable for at least 48 hours.

---

## 10. Post-Migration Activities

- Remove Fleet annotations and finalizers from resources (if desired).
- Delete Fleet GitRepos, Bundles, and related CRDs (optional, after decommission).
- Update DNS records if any service IPs changed.
- Update monitoring dashboards to use Argo CD metrics.
- Train team on Argo CD workflows.

---

**Document Version:** 1.0  
**Last Updated:** 2026-04-17
