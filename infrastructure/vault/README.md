# HashiCorp Vault on Kubernetes Deployment Guide

## Overview

HashiCorp Vault is deployed using the official Helm chart with integrated Raft storage for HA.

### Trust Model

| Component | Use Case | Trust Scope |
|-----------|----------|-------------|
| cert-manager + Let's Encrypt | Public ingress TLS | Browser/public client trusted |
| Vault PKI | Internal mTLS | Internal services only |

**IMPORTANT**: Vault is NOT used for public ACME certificates. cert-manager handles Let's Encrypt.

---

## Step 1: Deploy Vault with Helm

```bash
# Add HashiCorp Helm repository
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install Vault with HA (Raft)
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --version 0.27.0 \
  -f infrastructure/vault/manifests/values.yaml
```

### Alternative: Via Fleet

```bash
kubectl apply -k github.com/owner/repo/path//infrastructure/vault
```

---

## Step 2: Initialize Vault (First Time)

Vault in HA mode with Raft doesn't require manual unsealing if using auto-unseal or Kubernetes auth.

### Option A: Manual Init (Development)

```bash
# Initialize Vault
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=3 \
  -key-threshold=2 \
  -format=json > /tmp/vault-init.json

# Extract unseal keys
cat /tmp/vault-init.json | jq -r '.unseal_keys_b64[]'
cat /tmp/vault-init.json | jq -r '.root_token'

# Unseal Vault (run for each key, threshold times)
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY_1>
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY_2>
```

### Option B: Kubernetes Auth (Recommended for Production)

```bash
# Enable Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

# Configure Kubernetes auth
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Enable Vault PKI
kubectl exec -n vault vault-0 -- vault secrets enable pki
kubectl exec -n vault vault-0 -- vault secrets enable -path=pki-int pki
```

---

## Step 3: Verify Vault Status

```bash
# Check Vault pods are running
kubectl get pods -n vault -l app.kubernetes.io/name=vault

# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Check Raft cluster
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

Expected output should show:
- seal status: Unsealed
- mode: DR
- cluster: vault-cluster

---

## Step 4: Access Vault UI

The Vault UI is enabled and accessible via the ClusterIP service.

```bash
# Port-forward to Vault UI
kubectl port-forward -n vault svc/vault 8200:8200

# Access at: http://localhost:8200
# Use root token from init
```

Or via Ingress (if configured):
```bash
# Use the ingress at infrastructure/vault/manifests/ingress.yaml
# Note: Requires TLS certificate from cert-manager
```

---

## Step 5: Configure Vault PKI for Internal mTLS

See `infrastructure/vault/manifests/pki-setup.yaml` for automated setup.

### Manual PKI Configuration

```bash
# Enable PKI secrets engine
kubectl exec -n vault vault-0 -- vault secrets enable pki

# Tune for longer TTL
kubectl exec -n vault vault-0 -- vault secrets tune -max-lease-ttl=87600h pki

# Generate root CA (10 years)
kubectl exec -n vault vault-0 -- vault write -field=certificate pki/root/general/common_name="Internal Root CA" \
  ttl=87600h generate_root=true

# Enable intermediate PKI
kubectl exec -n vault vault-0 -- vault secrets enable -path=pki-int pki

# Create role for Kubernetes services
kubectl exec -n vault vault-0 -- vault write pki-int/roles/internal-service \
  allowed_domains="internal.example.com" \
  allow_subdomains=true \
  allow_wildcardCertificates=true \
  max_ttl=720h \
  ttl=24h

# Issue a certificate
kubectl exec -n vault vault-0 -- vault write -format=json pki-int/issue/internal-service \
  common_name="service.namespace.svc" \
  ttl=24h | jq -r '.data.certificate'
```

---

## Verification Commands

### Check Vault Pods
```bash
# All Vault pods should be Running
kubectl get pods -n vault -l app.kubernetes.io/name=vault

# Check logs
kubectl logs -n vault vault-0
```

### Check Raft Health
```bash
# Check Raft leader
kubectl exec -n vault vault-0 -- vault operator raft leader

# List peers
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

### Check TLS
```bash
# Check internal service certificate
kubectl exec -n vault vault-0 -- vault read pki-int/cert/ca

# Verify certificate chain
kubectl exec -n vault vault-0 -- vault read pki-int/cert/ca_chain
```

---

## Common Failure Modes

### 1. Vault Pods Not Starting

**Symptoms**: Pods in CrashLoopBackOff or Pending

**Debug**:
```bash
kubectl describe pod -n vault vault-0
kubectl logs -n vault vault-0
```

**Solutions**:
- Check storage class exists: `kubectl get storageclass local-path`
- Check resource limits
- Check PVs are bound: `kubectl get pv`

### 2. Vault Sealed After Restart

**Symptoms**: "Vault is sealed" after pod restart

**Solutions**:
- Use auto-unseal (AWS KMS, Azure Key Vault, GCP KMS, HashiCorp Cloud)
- Or manually unseal with key shares
- Or use Kubernetes-based unseal

### 3. Raft Join Fails

**Symptoms**: New pods can't join cluster

**Debug**:
```bash
kubectl logs -n vault vault-1 | grep -i raft
```

**Solutions**:
- Check network policies allow pod-to-pod communication
- Ensure storage has proper access modes
- Check join command in logs

---

## Scaling Vault

To scale Vault from 3 to 5 replicas:
```bash
kubectl scale statefulset vault --replicas=5 -n vault

# Wait for new pods to join cluster
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

---

## Files Created

- `infrastructure/vault/manifests/namespace.yaml` - vault namespace
- `infrastructure/vault/manifests/values.yaml` - Helm values (HA, Raft, 3 replicas)
- `infrastructure/vault/manifests/ingress.yaml` - Optional ingress for Vault UI
- `infrastructure/vault/manifests/pki-setup.yaml` - Vault PKI setup for internal mTLS

---

## Helm Commands Summary

```bash
# Install Vault
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --version 0.27.0 \
  -f infrastructure/vault/manifests/values.yaml

# Upgrade
helm upgrade vault hashicorp/vault \
  --namespace vault \
  -f infrastructure/vault/manifests/values.yaml

# Rollback
helm rollback vault 1 -n vault

# Uninstall
helm uninstall vault -n vault
kubectl delete namespace vault
```

---

## Security Note

Vault PKI certificates are for **internal use only**:
- Not trusted by browsers
- Not trusted by public clients
- Used for service-to-service mTLS within Kubernetes

Public TLS is handled by cert-manager + Let's Encrypt as configured in ingress-nginx.