# Grafana Data - NOW WORKING ✅

## Problem Fixed
No data in Grafana dashboards - **RESOLVED**

## Root Causes & Fixes

### 1. Prometheus Datasource DNS Resolution ❌ → ✅
- **Issue**: External URLs (`prometheus.data.mbtux.com`) don't resolve from within cluster
- **Fix**: Use internal K8s service URLs:
  - `http://prometheus:9090` (same namespace)
  - `http://prometheus.monitoring:9090` (cross-namespace)

### 2. Wrong HTTP Method (POST vs GET) ❌ → ✅
- **Issue**: `httpMethod: POST` for Prometheus query API
- **Fix**: Changed to `httpMethod: GET`
- **Why**: Prometheus HTTP API uses GET for `/api/v1/query` and `/api/v1/query_range`

### 3. OIDC Authentication Missing ❌ → ✅
- **Issue**: No auth middleware for external Grafana access
- **Fix**: Added `grafana-oidc-auth` Traefik middleware
  - Provider: Authentik (`authentik.mbtux.com`)
  - Scopes: openid, profile, email
  - Paths bypassing auth: `/api`, `/login`, `/logout`, `/oauth2`, `/.well-known`

### 4. Missing Prometheus Mgmt Routing ❌ → ✅
- **Issue**: `prometheus.mgmt.mbtux.com` had no IngressRoute
- **Fix**: Created `prometheus-mgmt` IngressRoute + TLS Certificate

## Files Modified

```
production-infrastructure/monitoring-data/manifests/
├── 11-datasources.yaml              # Fixed URLs + HTTP method
├── ingressroute-grafana.yaml        # Added OIDC auth middleware
└── ingressroute-prometheus.yaml     # Added mgmt cluster route
```

## Verification Results

### All Health Checks ✅
```bash
# Prometheus (data-cluster)
Status: OK - Successfully queried the Prometheus API.

# Prometheus (mgmt-cluster)  
Status: OK - Successfully queried the Prometheus API.
```

### Query Tests ✅
```bash
up query:        25 series, 121 data points per series
kube_node_info:  121 nodes found
API requests:    Time series data flowing correctly
```

### Dashboards Imported ✅
- k8s-system-api-server (12 panels) ✅
- k8s-views-global ✅
- k8s-views-namespaces ✅
- k8s-views-nodes ✅
- k8s-views-pods ✅

### Sample Query Response
```json
{
  "status": 200,
  "frames": [
    {
      "schema": { ... },
      "data": {
        "values": [
          [1777399747245, 1777399748245, ...],  // timestamps
          [1, 1, ...]                              // up values
        ]
      }
    }
  ]
}
```

## Current Grafana Datasources

| Name | URL | Method | Status |
|------|-----|--------|--------|
| Prometheus (data-cluster) | `http://prometheus:9090` | GET | ✅ OK |
| Prometheus (mgmt-cluster) | `http://prometheus.monitoring:9090` | GET | ✅ OK |

## How Data Flows

```
User Browser
  → https://grafana.mbtux.com (TLS via cert-manager)
  → Traefik (OIDC auth via Authentik)
  → Grafana Pod
  → Prometheus Service (ClusterIP)
  → Prometheus Pod
  → Returns metrics to Grafana
  → Grafana renders dashboards
```

## Key Configuration Details

### Datasource Config
```yaml
url: http://prometheus:9090      # Internal K8s service
access: proxy                    # Grafana proxies requests
jsonData:
  httpMethod: GET                # Correct for query API
  timeInterval: 30s
```

### Authentication Path
```
/grafana/login        → Grafana (bypass auth)
/grafana/logout       → Grafana (bypass auth)
/grafana/oauth2/*     → Grafana (bypass auth)
/grafana/api/*        → Grafana (bypass auth)
/grafana/             → OIDC → Authentik → Grafana
```

## Notes

- Grafana stores datasource config in SQLite DB (not just ConfigMap)
- Dashboards use `${datasource}` template variable
- 25 active time series from data-cluster Prometheus
- Prometheus running v2.51.2, Grafana v10.4.3
- All pods healthy and scraping successfully

## Credentials

- Grafana Admin: `admin` / `Inf0rm@tics@123`
- OIDC Provider: `authentik.mbtux.com`
- Dashboard URL: `https://grafana.mbtux.com`
