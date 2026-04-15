# Dual PKI Architecture: Cloudflare + Vault

## Why Dual PKI?

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         CLOUDFLARE EDGE                                  │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Full (Strict) Mode: Requires valid public cert OR Cloudflare  │   │
│  │  Origin Certificate (trusted by Cloudflare, NOT by browsers)   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ════════════════╪═══════════════
                       Edge TLS      │    Internal mTLS
                    (Cloudflare)     │    (Vault PKI)
                                    ▼                    ▼
┌─────────────────────────────────┐  ┌────────────────────────────────────┐
│        ORIGIN (K8s)              │  │       SERVICE-TO-SERVICE           │
│  ┌───────────────────────────┐  │  │  ┌──────────┐     ┌──────────┐  │
│  │   NGINX Ingress           │  │  │  │ Service A │────▶│ Service B │  │
│  │   - TLS from Vault       │  │  │  │ (mTLS)    │     │ (mTLS)    │  │
│  │   - Cloudflare Origin    │  │  │  └──────────┘     └──────────┘  │
│  │     Certificate          │  │  │       │                    │     │
│  └───────────────────────────┘  │  │       └────────┬───────────┘     │
└─────────────────────────────────┘  │  ┌──────────────┴──────────────┐  │
                                     │  │     Vault PKI (mbtux.com)    │  │
                                     │  │     - Internal CA            │  │
                                     │  │     - Service mesh certs    │  │
                                     │  └─────────────────────────────┘  │
                                     │          INTERNAL NETWORK         │
                                     └────────────────────────────────────┘
```

### The Problem
- **Cloudflare does NOT trust private CAs** (HashiCorp Vault PKI)
- When you enable "Full (Strict)" in Cloudflare, it verifies the origin certificate
- Browser trust stores don't include your private root CA
- Result: Connection fails with `ERR_CERT_AUTHORITY_INVALID` or similar

### The Solution: Dual PKI
1. **Edge TLS** (Cloudflare → Origin): Use Cloudflare Origin Certificates or Let's Encrypt
2. **Internal TLS/mTLS** (Service-to-Service): Use Vault PKI for full control

---

## Certificate Flow

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   Cloudflare     │────▶│   NGINX Ingress  │────▶│   Backend App    │
│   (Full Strict)  │ TLS │   (Terminates)   │ HTTP│                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
              Cloudflare Origin Cert         Vault PKI Cert
              (Publicly trusted by CF)       (Private CA - internal)
              - outline.mbtux.com            - Service mesh
              - 30-day rotation             - mTLS between services
```

---

## Implementation

### 1. Edge TLS: Cloudflare Origin Certificate (Vault-issued)

**Requirements:**
- Certificate must be issued by an intermediate CA that Cloudflare trusts OR
- Use Cloudflare's own Origin Certificate (generated in Cloudflare dashboard)

**Vault Configuration:**
```bash
# Enable PKI if not already done
vault secrets enable -path=pki-int pki

# Create role with appropriate TTL (must be < CA expiry)
vault write pki-int/roles/cloudflare-origin \
  issuer_ref=default \
  allow_any_name=true \
  max_ttl=8760h

# Issue certificate (TTL must be less than CA expiry)
vault write -format=json pki-int/issue/cloudflare-origin \
  common_name="outline.mbtux.com" \
  ttl=30d | jq -r '.data.certificate, .data.private_key' > tls.key
```

**Kubernetes Secret:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: outline-tls
  namespace: outline
type: kubernetes.io/tls
data:
  # base64 encoded cert + key
```

**NGINX Ingress:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: outline
  namespace: outline
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - outline.mbtux.com
      secretName: outline-tls  # Vault-issued cert
  rules:
    - host: outline.mbtux.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: outline
                port:
                  number: 80
```

### 2. Internal mTLS: Vault PKI

**Vault PKI Setup:**
```bash
# Already configured
vault secrets enable -path=pki-int pki
vault write pki-int/roles/mbtux \
  allow_any_name=true \
  allow_subdomains=true \
  max_ttl=8760h

# Issue internal certificates
vault write pki-int/issue/mbtux \
  common_name="service-a.internal.mbtux.com" \
  ttl=8760h
```

**Use Cases:**
- Service mesh (Istio, Linkerd)
- Internal API authentication
- Database connections
- Legacy app modernization

---

## Best Practices

### 1. Certificate Rotation

| Type | TTL | Rotation Method |
|------|-----|-----------------|
| Cloudflare Origin | 30 days | Automated script + Kubernetes secret update |
| Vault PKI (Internal) | 1 year | cert-manager + Vault issuer |
| Browser-trusted | 90 days | Let's Encrypt (Cloudflare handles) |

**Rotation Script:**
```bash
#!/bin/bash
# rotate-origin-cert.sh - Run as Kubernetes CronJob

VAULT_ADDR="http://vault:8200"
VAULT_TOKEN=$(cat /vault/secrets/token)
DOMAINS=("outline.mbtux.com" "authentik.mbtux.com")

for DOMAIN in "${DOMAINS[@]}"; do
  vault write -format=json pki-int/issue/cloudflare-origin \
    common_name="$DOMAIN" ttl=30d > /tmp/cert.json
  
  kubectl create secret tls "${DOMAIN}-tls" \
    --cert=<(jq -r '.data.certificate' /tmp/cert.json) \
    --key=<(jq -r '.data.private_key' /tmp/cert.json) \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

### 2. Port Separation

```
┌─────────────────────────────────────────────────────────┐
│                    KUBERNETES CLUSTER                   │
│                                                          │
│  EXTERNAL (Layer 4/7 LoadBalancer)                      │
│  ├─ Port 443: Edge TLS (Cloudflare Origin Cert)        │
│  └─ Port 8443: mTLS Ingress (Vault PKI)                │
│                                                          │
│  INTERNAL (ClusterIP)                                   │
│  ├─ Port 443: Service mesh mTLS                        │
│  └─ Port 80: HTTP (no TLS)                             │
└─────────────────────────────────────────────────────────┘
```

### 3. Cloudflare Configuration

**Settings:**
- **SSL/TLS Mode**: Full (Strict)
- **Origin Server**: Use Cloudflare Origin Certificate OR
- **TLS 1.3**: Enabled
- **Minimum TLS Version**: 1.2

**Important:** When using "Full (Strict)":
- Cloudflare validates the certificate IS valid (not expired, matches hostname)
- Cloudflare DOES NOT validate against a trusted CA store
- BUT: If cert is expired or hostname doesn't match → connection fails
- Best practice: Use Cloudflare-generated Origin Certificates (not Vault)

### 4. Security Posture

```
┌────────────────────────────────────────────────────────┐
│                  SECURITY LAYERS                       │
├────────────────────────────────────────────────────────┤
│  Layer 1: Cloudflare Edge                              │
│  - DDoS protection                                     │
│  - WAF rules                                           │
│  - Bot management                                       │
│  - Full (Strict) TLS                                    │
├────────────────────────────────────────────────────────┤
│  Layer 2: NGINX Ingress (Origin)                       │
│  - TLS 1.3 only                                        │
│  - Modern cipher suite                                 │
│  - HSTS enabled                                        │
├────────────────────────────────────────────────────────┤
│  Layer 3: Vault PKI (Internal)                        │
│  - mTLS for service-to-service                         │
│  - Mutual authentication                               │
│  - Certificate validation at application level         │
└────────────────────────────────────────────────────────┘
```

---

## Common Pitfalls

### ❌ Attempting to make Cloudflare trust Vault PKI
**Problem:** Cloudflare cannot be configured to trust custom CAs
**Solution:** Use Cloudflare Origin Certificates or Let's Encrypt at edge

### ❌ Using long TTL for Cloudflare Origin certs
**Problem:** CA expiry may limit maximum certificate TTL
**Solution:** Use 30-day TTL, automate rotation with CronJob

### ❌ Mixing internal and edge certificates
**Problem:** Confusing which cert is used where
**Solution:** Clearly label secrets: `outline-edge-tls` vs `outline-mtls`

### ❌ Not validating certs at application level
**Problem:** Service-to-service communication may not validate
**Solution:** Use service mesh or implement cert validation in code

### ❌ Single point of failure in certificate management
**Problem:** Manual rotation = forgotten certificates
**Solution:** Automated rotation with monitoring and alerts

---

## Quick Reference

| Scenario | Certificate Source | Placement |
|----------|-------------------|-----------|
| Cloudflare → Origin | Cloudflare Origin Cert (or Vault-issued*) | Ingress TLS secret |
| Browser → Cloudflare | Let's Encrypt (automatic) | Cloudflare handles |
| Service A → Service B | Vault PKI (pki-int) | Service mesh |
| Kubernetes API | etcd CA | Control plane |
| Ingress Controller | Vault PKI | Controller cert |

*Vault-issued works for Cloudflare ONLY IF the intermediate CA is not expired and the cert validates correctly