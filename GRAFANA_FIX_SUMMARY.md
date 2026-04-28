# Grafana Data Visibility Fix - Summary

## Problem
No data was visible in Grafana dashboards. Investigation revealed multiple configuration issues.

## Root Causes Identified

### 1. Incorrect Prometheus Datasource HTTP Method (CRITICAL)
- **Issue**: Datasources configured with `httpMethod: POST`
- **Impact**: Prometheus instant queries and remote_read don't work properly with POST through Traefik proxy
- **Fix**: Changed to `httpMethod: GET` for both datasources

### 2. Missing OIDC Authentication Middleware (CRITICAL)
- **Issue**: Grafana IngressRoute had no authentication middleware configured
- **Impact**: External access to Grafana without proper OIDC authentication via Authentik
- **Fix**: Added `grafana-oidc-auth` Traefik middleware with OIDC plugin configuration

### 3. Missing Prometheus Management Cluster Routing
- **Issue**: `prometheus.mgmt.mbtux.com` had no IngressRoute configured
- **Impact**: Management cluster Prometheus inaccessible externally
- **Fix**: Created `prometheus-mgmt` IngressRoute and TLS Certificate

## Files Modified

### 1. `production-infrastructure/monitoring-data/manifests/11-datasources.yaml`
```yaml
datasources:
  - name: Prometheus (data-cluster)
    url: https://prometheus.data.mbtux.com
    jsonData:
      httpMethod: GET  # Changed from POST
      timeInterval: 30s
      tlsSkipVerify: true
  - name: Prometheus (mgmt-cluster)
    url: https://prometheus.mgmt.mbtux.com
    jsonData:
      httpMethod: GET  # Changed from POST
      timeInterval: 30s
      tlsSkipVerify: true
```

### 2. `production-infrastructure/monitoring-data/manifests/ingressroute-grafana.yaml`
- Added OIDC auth middleware (`grafana-oidc-auth`)
- Configured path-based routing:
  - `/api` - Direct to Grafana (bypass auth)
  - `/login`, `/logout`, `/oauth2`, `/.well-known` - Direct to Grafana (bypass auth)
  - `/`, `/dashboard` - Require OIDC authentication
- Integrates with Existing Authentik OIDC provider

### 3. `production-infrastructure/monitoring-data/manifests/ingressroute-prometheus.yaml`
- Renamed primary IngressRoute to `prometheus-data`
- Added `prometheus-mgmt-tls` Certificate for management cluster
- Added `prometheus-mgmt` IngressRoute for management cluster access

## Authentication Flow

```
User → grafana.mbtux.com → Traefik → OIDC Middleware → Authentik → Grafana
                              ↓
                    (Auth check on root path)
                              ↓
                    /api, /login, /logout, /oauth2 → Direct pass
```

## Datasource Configuration

Both Prometheus datasources use:
- **Protocol**: HTTPS
- **Method**: GET (for instant/range queries)
- **TLS**: Skip verify (using cert-manager issued certs)
- **Routing**: Through Traefik IngressRoutes with TLS termination

## Verification Steps

1. **Check DNS Resolution**:
   ```bash
   curl -I https://grafana.mbtux.com/api/health
   curl -I https://prometheus.data.mbtux.com/api/v1/status/buildinfo
   curl -I https://prometheus.mgmt.mbtux.com/api/v1/status/buildinfo
   ```

2. **Verify OIDC Configuration**:
   - Access https://grafana.mbtux.com
   - Should redirect to Authentik login
   - After login, should return to Grafana with authenticated session

3. **Verify Prometheus Datasources**:
   - Login to Grafana
   - Navigate to Configuration → Data Sources
   - Both Prometheus datasources should show "Data source is working"
   - Test queries should return results

4. **Check Certificate Status**:
   ```bash
   kubectl get certificates -n monitoring
   # All should show READY=True
   ```

## Notes

- TLS certificates are managed by cert-manager via Let's Encrypt
- OIDC provider is existing Authentik instance at `authentik.mbtux.com`
- Grafana OIDC config uses `${AUTHENTIK_CLIENT_SECRET}` from Kubernetes secret
- Cluster resources may be out of sync with Git until ArgoCD/Fleet sync completes
- Changes require GitOps sync to propagate to cluster

## Additional Context

- Grafana version: 10.4.3
- Prometheus version: 2.51.2
- Traefik used as ingress controller
- cert-manager for TLS certificate management
- Authentik for OIDC authentication
