# Cert-Manager + Let's Encrypt Deployment Guide

## Overview

This setup provides **public browser-trusted TLS certificates** for Kubernetes Ingress using Let's Encrypt with Cloudflare DNS validation.

### Trust Model

| Component | Use Case | Trust Scope |
|-----------|----------|-------------|
| cert-manager + Let's Encrypt | Public ingress TLS | Browser/public client trusted |
| Vault PKI | Internal mTLS | Internal services only |

**IMPORTANT**: Vault OSS does NOT act as an ACME client. cert-manager handles public certificates; Vault handles internal PKI.

---

## Prerequisites

1. Kubernetes cluster (k3s / Rancher)
2. Helm 3.x installed
3. Cloudflare account with DNS
4. Domain: `example.com` (replace with your domain)

---

## Step 1: Deploy Cert-Manager

```bash
# Add Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager CRDs first
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.crds.yaml

# Install cert-manager with Helm
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.0 \
  --set installCRDs=true \
  --set nodeSelector.kubernetes.io/arch=amd64
```

Or via Fleet:
```bash
kubectl apply -k github.com/owner/repo/path//infrastructure/cert-manager
```

---

## Step 2: Configure Cloudflare API Token

### Create Cloudflare API Token

1. Log in to Cloudflare Dashboard
2. Go to Profile > API Tokens
3. Create New Token with these permissions:
   - **Zone**: Read (if using zone-scoped)
   - **DNS**: Edit (required for DNS-01 challenge)
4. Use template: "Edit zone DNS" or custom token

### Store API Token

```bash
# Edit the secret and replace CHANGEME_CLOUDFLARE_API_TOKEN
kubectl edit secret cloudflare-api-token -n cert-manager -o yaml
```

Or apply updated secret:
```bash
kubectl apply -f infrastructure/cert-manager/manifests/cloudflare-api-token.yaml
```

---

## Step 3: Verify ClusterIssuer

```bash
# Check ClusterIssuer status
kubectl get clusterissuer letsencrypt-prod -o wide

# Describe for details
kubectl describe clusterissuer letsencrypt-prod

# Verify it's ready
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[*].type}'
```

Expected output: `Ready`

---

## Step 4: Deploy Ingress with TLS

```bash
# Apply sample ingress
kubectl apply -f infrastructure/cert-manager/manifests/sample-ingress.yaml

# Watch certificate being created
kubectl get certificate -w

# Check TLS secret
kubectl get secret example-com-tls -o yaml
```

---

## Verification Commands

### Check Certificate Status
```bash
# List certificates
kubectl get certificates.cert-manager.io --all-namespaces

# Describe certificate
kubectl describe certificate example-com-tls

# Check ACME orders
kubectl get orders.cert-manager.io -A
```

### Check Cert-Manager Logs
```bash
# View cert-manager controller logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager -c controller

# Follow logs in real-time
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager -c controller -f
```

### Verify TLS Secret
```bash
# Check secret exists and has correct keys
kubectl get secret example-com-tls -o jsonpath='{.type}'  # should be: kubernetes.io/tls

# Decode certificate
kubectl get secret example-com-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text

# Check expiry
kubectl get secret example-com-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
```

---

## Common Failure Modes

### 1. Certificate Not Created

**Symptoms**: Secret `example-com-tls` not created

**Debug**:
```bash
kubectl describe certificate example-com-tls
# Look for: "Waiting for CertificateRequest" or validation errors
```

**Solutions**:
- Check ClusterIssuer is Ready: `kubectl get clusterissuer letsencrypt-prod`
- Verify Cloudflare API token has DNS Edit permission
- Check DNS is managed by Cloudflare

### 2. DNS-01 Challenge Fails

**Symptoms**: Order stuck in "pending" state

**Debug**:
```bash
kubectl describe order <order-name>
# Look for: "Could not resolve domain" or DNS propagation issues
```

**Solutions**:
- Verify Cloudflare API token in secret
- Check domain resolves to ingress IP
- Wait for DNS propagation (can take minutes)
- Use STAGING first to debug

### 3. Cloudflare API Token Invalid

**Symptoms**: "cloudflare: unauthorized"

**Solutions**:
- Recreate Cloudflare API token with DNS Edit permission
- Update secret with new token
- Verify token works: `curl -H "Authorization: Bearer $TOKEN" "https://api.cloudflare.com/client/v4/zones"`

---

## Using STAGING First

Let's Encrypt STAGING is recommended for testing to avoid rate limits.

```yaml
# In ingress annotations, use staging:
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-staging
```

Once verified working, switch to production:
```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
```

---

## Certificate Renewal

cert-manager automatically renews certificates:
- Renewal happens 30 days before expiry (configurable)
- Renewal triggers new DNS-01 challenge
- No user intervention required

Check renewal:
```bash
kubectl get certificate example-com-tls -o jsonpath='{.status.notAfter}'
```

---

## Wildcard Certificates

The ClusterIssuer supports wildcards via DNS-01:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-example-com
  namespace: cert-manager
spec:
  secretName: wildcard-example-com-tls
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-prod
  dnsNames:
    - "*.example.com"
  secretTemplate:
    annotations:
      cert-manager.io/auto-signed: "true"
```

---

## Integration with Vault

While cert-manager handles public certificates, Vault can be used for internal mTLS:

```bash
# Request certificate from Vault PKI
vault write pki-int/issue/k8s-service \
  common_name="service.namespace.svc" \
  ttl=24h

# This is for internal service-to-service TLS only
# Not browser-trusted
```

---

## Files Created

- `infrastructure/cert-manager/manifests/namespace.yaml` - cert-manager namespace
- `infrastructure/cert-manager/manifests/cloudflare-api-token.yaml` - Cloudflare API token secret + ClusterIssuers (STAGING + PRODUCTION)
- `infrastructure/cert-manager/manifests/sample-ingress.yaml` - Example ingress with TLS

---

## Helm Commands Summary

```bash
# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.0 \
  --set installCRDs=true

# Upgrade
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.15.0

# Uninstall
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
```