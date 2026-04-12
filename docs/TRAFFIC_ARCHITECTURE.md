# Target-State Traffic Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                    INTERNET                                          │
└─────────────────────────────────────┬───────────────────────────────────────────────┘
                                      │
                    ┌─────────────────▼─────────────────┐
                    │         CLOUDFLARE EDGE              │
                    │  ┌─────────────────────────────┐   │
                    │  │  DNS (mbtux.com)            │   │
                    │  │  *.mbtux.com               │   │
                    │  ├─────────────────────────────┤   │
                    │  │  HTTPS (Full Strict)        │   │
                    │  │  TLS 1.3                   │   │
                    │  ├─────────────────────────────┤   │
                    │  │  WAF (Security Level)       │   │
                    │  │  Rate Limiting              │   │
                    │  ├─────────────────────────────┤   │
                    │  │  Bot Management             │   │
                    │  ├─────────────────────────────┤   │
                    │  │  Load Balancing             │   │
                    │  │  (Origin Pool: Traefik)     │   │
                    │  └─────────────────────────────┘   │
                    └─────────────────────────────────────┘
                                      │ :443 (HTTPS only)
                    ┌─────────────────▼─────────────────┐
                    │    TRAEFIK INGRESS CONTROLLER    │
                    │  ┌─────────────────────────────┐│
                    │  │  DaemonSet (recommended)    ││
                    │  │  or Deployment with HA      ││
                    │  ├─────────────────────────────┤│
                    │  │  EntryPoints: web, websecure││
                    │  │  TLS: Cloudflare Origin CA ││
                    │  ├─────────────────────────────┤│
                    │  │  Middleware:                ││
                    │  │  - headers (security)       ││
                    │  │  - redirect-https          ││
                    │  │  - rate-limit              ││
                    │  ├─────────────────────────────┤│
                    │  │  IngressRoute CRDs          ││
                    │  └─────────────────────────────┘│
                    └─────────────────────────────────┘
                                      │
                    ┌─────────────────▼─────────────────┐
                    │    KUBERNETES SERVICES          │
                    │  ┌─────────────────────────────┐│
                    │  │  immich.mbtux.com          ││
                    │  │  → immich-web:3000         ││
                    │  ├─────────────────────────────┤│
                    │  │  sure.mbtux.com            ││
                    │  │  → sure:80                 ││
                    │  ├─────────────────────────────┤│
                    │  │  taiga.mbtux.com           ││
                    │  │  → taiga:80                 ││
                    │  ├─────────────────────────────┤│
                    │  │  wekan.mbtux.com           ││
                    │  │  → wekan:80                ││
                    │  └─────────────────────────────┘│
                    └─────────────────────────────────┘
```

## Traffic Flow

| Step | Component | Protocol | Description |
|------|-----------|----------|-------------|
| 1 | Client | HTTPS | Browser connects to Cloudflare |
| 2 | Cloudflare Edge | TLS 1.3 |-terminates HTTPS, inspects, filters |
| 3 | Cloudflare → Traefik | HTTPS | Origin request with Cloudflare CA |
| 4 | Traefik | HTTP | Routes to backend service |
| 5 | Kubernetes Service | TCP | Internal cluster networking |
| 6 | Pod | HTTP | Application response |

---

## Cloudflare Configuration

### DNS Strategy

| Type | Name | Target | Proxy Status |
|------|------|--------|--------------|
| A | mbtux.com | <origin IP> | Proxy |
| CNAME | *.mbtux.com | mbtux.com | Proxy |

### SSL/TLS Mode

- **Mode**: Full (Strict)
- **Origin Server**: Issue Origin CA certificate (via Cloudflare dashboard)
- **Certificate**: `*.mbtux.com` origin certificate (auto-renewal)

### Origin Protection

#### Option 1: Cloudflare Authenticated Origin Pulls (Recommended)
```yaml
# Enable in Cloudflare dashboard
# SSL/TLS → Origin Server →Authenticated Origin Pulls: On
```

#### Option 2: Allow Cloudflare IPs Only
```
# Configure in nginx/ Traefik to allow only:
173.245.48.0/20
103.21.244.0/20
103.22.200.0/20
103.31.4.0/20
141.101.64.0/18
108.162.192.0/18
172.64.0.0/13
172.80.0.0/10
131.0.32.0/19
151.101.0.0/16
194.60.96.0/19
190.93.240.0/20
188.114.96.0/20
```

### Traffic Management

| Feature | Implementation | Use Case |
|---------|----------------|----------|
| Load Balancing | Cloudflare Load Balancer | Primary/secondary origin |
| Canary | trafficManager + percentage | Progressive rollouts |
| A/B Testing | Cloudflare Workers | Feature flags |
| Failover | Health checks + origin pool | DR strategy |

---

## Traefik Configuration

### Deployment Mode

| Option | Pros | Cons |
|--------|-----|-----|
| **DaemonSet** | High availability, node-level | Uses one pod per node |
| Deployment + HPA | Resource efficient | Single point of failure without pod anti-affinity |

**Recommendation**: Deploy a small cluster with pod anti-affinity or DaemonSet with node selectors.

### EntryPoints

```yaml
# web (port 80)
- http redirec→ https

# websecure (port 443)
- TLS termination
```

### CRD Selection

| CRD | Use Case | Recommendation |
|-----|---------|----------------|
| Ingress | Native K8s | Standard, less feature-rich |
| IngressRoute | Traefik-native | Full features (middleware, weighted) |

**Recommendation**: Use IngressRoute for production (supports middleware, weighted services).

### TLS Configuration

```yaml
# TLS options for Cloudflare connection
tls:
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
```

### Middleware

| Middleware | Purpose |
|------------|---------|
| headers | Security headers (HSTS, X-Frame-Options) |
| redirect-https | HTTP → HTTPS redirect |
| rate-limit | Throttle requests per IP |
| compress | Gzip compression |

### Observability

| Metric | Implementation |
|--------|---------------|
| Metrics | Prometheus endpoint `/metrics` |
| Access Logs | JSON format to stdout |
| Tracing | OpenTelemetry (optional) |

---

## Security Checklist

- [ ] No Kubernetes service exposed as LoadBalancer/NodePort
- [ ] All traffic through Cloudflare
- [ ] Origin protected (Cloudflare IPs or Authenticated Origin Pulls)
- [ ] TLS 1.3 with modern cipher suites
- [ ] Security headers via Traefik middleware
- [ ] Rate limiting enabled
- [ ] WAF rules configured in Cloudflare
- [ ] Access logs forwarded to observability
- [ ] Health checks configured for failover