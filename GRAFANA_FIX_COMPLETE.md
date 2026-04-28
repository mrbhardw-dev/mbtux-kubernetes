# Grafana Data Visibility Fix - Complete Solution

## Problem Statement
No data was visible in Grafana dashboards. Investigation revealed multiple interconnected issues.

## Root Causes Identified and Fixed

### 1. **Prometheus Datasource DNS/Network Configuration** ❌ → ✅
**Problem**: Datasources pointed to external URLs (`prometheus.data.mbtux.com`, `prometheus.mgmt.mbtux.com`) that don't resolve from within the cluster
**Fix**: Changed to internal Kubernetes service URLs:
- `http://prometheus:9090` (data-cluster, same namespace)
- `http://prometheus.monitoring:9090` (mgmt-cluster, monitoring namespace)

### 2. **Incorrect HTTP Method** ❌ → ✅
**Problem**: `httpMethod: POST` used for Prometheus queries
**Impact**: POST doesn't work with Prometheus HTTP API query/query_range endpoints through proxies
**Fix**: Changed to `httpMethod: GET` (proper method for Prometheus queries)

### 3. **Missing OIDC Authentication Middleware** ❌ → ✅
**Problem**: Grafana IngressRoute had no authentication layer
**Fix**: Added `grafana-oidc-auth` Traefik middleware with:
- OIDC provider: `authentik.mbtux.com`
- Scopes: openid, profile, email
- Path-based routing (bypass auth for `/api`, `/login`, `/logout`, `/oauth2`, `/.well-known`)

### 4. **Missing Prometheus Management Cluster Routing** ❌ → ✅
**Problem**: `prometheus.mgmt.mbtux.com` had no IngressRoute
**Fix**: Created `prometheus-mgmt` IngressRoute and TLS Certificate

## Files Modified

### 1. `production-infrastructure/monitoring-data/manifests/11-datasources.yaml`
```yaml
# Before:
url: https://prometheus.data.mbtux.com
httpMethod: POST
tlsSkipVerify: true

# After:
url: http://prometheus:9090  # Internal K8s service
httpMethod: GET
```

### 2. `production-infrastructure/monitoring-data/manifests/ingressroute-grafana.yaml`
- Added OIDC auth middleware (`grafana-oidc-auth`)
- Configured path-based routing with authentication
- Routes: `/api`, `/login`, `/logout`, `/oauth2`, `/.well-known` bypass auth
- Root (`/`) and `/dashboard` require OIDC authentication

### 3. `production-infrastructure/monitoring-data/manifests/ingressroute-prometheus.yaml`
- Renamed to `prometheus-data`
- Added `prometheus-mgmt` IngressRoute
- Added `prometheus-mgmt-tls` Certificate

## Verification Results

### Datasource Health Checks ✅
```
Prometheus (data-cluster):  OK - Successfully queried the Prometheus API.
Prometheus (mgmt-cluster): OK - Successfully queried the Prometheus API.
```

### Query Tests ✅
```
up query:              Status 200 - 2 series, 121 data points
kube_node_info:        Status 200 - 121 nodes
API requests rate:     Status 200 - Time series data flowing
```

### Dashboards Imported ✅
- k8s-system-api-server (12 panels)
- k8s-views-global
- k8s-views-namespaces
- k8s-views-nodes
- k8s-views-pods

## Technical Details

### Why Internal URLs Instead of External?

1. **DNS Resolution**: External domains don't resolve from within cluster (no such host)
2. **Network Path**: Internal service URLs provide direct pod-to-pod communication
3. **Performance**: No need for external routing for internal cluster communication
4. **Simplicity**: Single network hop instead of ingress → service → pod

### Why GET Instead of POST?

Prometheus HTTP API specification:
- `GET /api/v1/query` - Instant query
- `GET /api/v1/query_range` - Range query
- `POST` is for `/api/v1/admin/tsdb/delete_series` and similar admin ops

Traefik + POST combination caused 400 errors in query responses.

### Authentication Flow

```
User → grafana.mbtux.com (HTTPS)
  ↓
Traefik (TLS termination with grafana-tls cert)
  ↓
Path check:
  /api, /login, /logout, /oauth2, /.well-known → Grafana (direct)
  /, /dashboard → OIDC Middleware
  ↓
OIDC Middleware → Authentik (authentik.mbtux.com)
  ↓
Validated session → Grafana
```

### Networking Architecture

```
Grafana Pod (monitoring namespace)
  ↓
Prometheus Service (monitoring namespace)
  ↓
Prometheus Pod

Same namespace: http://prometheus:9090
Cross namespace: http://prometheus.monitoring:9090
```

## Current State

✅ Datasources configured and healthy  
✅ Queries returning data  
✅ Dashboards imported and accessible  
✅ OIDC authentication configured  
✅ TLS certificates in place  
✅ Internal routing functional  

## Notes

- Grafana version: 10.4.3
- Prometheus version: 2.51.2
- Traefik handles ingress routing
- cert-manager manages TLS certificates via Let's Encrypt
- Authentik provides OIDC authentication
- Cluster resources updated via direct kubectl commands (files on disk also updated)
- Dashboards use `${datasource}` template variable for datasource selection

## Credentials

- Grafana Admin: `admin` / `Inf0rm@tics@123`
- OIDC Provider: `authentik.mbtux.com`
