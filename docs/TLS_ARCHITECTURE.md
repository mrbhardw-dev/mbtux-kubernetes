# =============================================================================
# TLS ARCHITECTURE DOCUMENTATION
# =============================================================================
#
# Architecture: End-to-End HTTPS via Cloudflare Tunnel
# 
# Flow: User → Cloudflare Edge (HTTPS) → cloudflared (TLS) → NGINX (TLS) → App
#
# =============================================================================

## COMPONENTS

### 1. TLS Secret (cloudflare-origin-cert)
- Location: infrastructure/tls/secret-template.yaml
- Namespace: ingress-nginx
- Type: kubernetes.io/tls
- Contains: TLS certificate and private key for mbtux.com

### 2. Ingress Resources
- Location: infrastructure/ingress/resources.yaml
- Each app has its own Ingress with TLS configured
- Uses secretName: cloudflare-origin-cert

### 3. cloudflared Config
- Location: infrastructure/cloudflared-data/manifests/configmap.yaml
- Routes: *.mbtux.com → NGINX HTTPS (port 443)
- noTLSVerify: true (skips origin TLS verification)

### 4. Certificate Rotation CronJob
- Location: infrastructure/tls/cert-rotation-cronjob.yaml
- Schedule: Weekly (Sunday 2am)
- Supports multiple secret sources (Vault, S3, Git)

---

## DEPLOYMENT

### Manual Deployment

```bash
# 1. Apply TLS secret (with real certs)
kubectl apply -f infrastructure/tls/secret-template.yaml

# 2. Apply Ingress resources
kubectl apply -f infrastructure/ingress/resources.yaml

# 3. Apply cloudflared config
kubectl apply -f infrastructure/cloudflared-data/manifests/configmap.yaml

# 4. Restart NGINX to pick up TLS
kubectl rollout restart deployment -n ingress-nginx nginx-ingress-ingress-nginx-controller
```

### Via Fleet GitOps

The manifests in infrastructure/ are automatically synced via Fleet GitRepo.

---

## CERTIFICATE ROTATION

### Option A: Using CronJob (included)

1. Configure secret source (Vault, S3, or Git) in CronJob env vars
2. Apply: `kubectl apply -f infrastructure/tls/cert-rotation-cronjob.yaml`
3. Rotation runs weekly automatically

### Option B: Manual

```bash
# 1. Update certificate in secret
kubectl create secret tls cloudflare-origin-cert \
  --namespace=ingress-nginx \
  --cert=/path/to/new/cert.pem \
  --key=/path/to/new/key.pem \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Restart NGINX
kubectl rollout restart deployment -n ingress-nginx nginx-ingress-ingress-nginx-controller
```

### Option C: GitOps (ArgoCD/Flux)

1. Update certificate in Git repository
2. GitOps syncs automatically to cluster

---

## BONUS: Proper TLS Validation

To replace noTLSVerify: true with proper CA validation:

```yaml
# 1. Mount CA ConfigMap in cloudflared deployment
volumes:
- name: ca-cert
  configMap:
    name: cloudflare-origin-ca

# 2. Update config to use caPool
originRequest:
  caPool: /etc/cloudflared/certs/ca.crt
```

---

## VERIFICATION

### Test End-to-End HTTPS

```bash
# Test all apps
for app in outline sure authentik grafana; do
  echo "=== Testing $app.mbtux.com ==="
  curl -kvI "https://$app.mbtux.com" | grep "HTTP\|SSL\|subject"
done
```

### Check TLS Certificate

```bash
# View certificate
kubectl get secret cloudflare-origin-cert -n ingress-nginx -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates -subject

# Check expiration
kubectl get secret cloudflare-origin-cert -n ingress-nginx -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
```

### Check NGINX TLS Config

```bash
# Verify NGINX is using the correct cert
kubectl exec -n ingress-nginx deploy/nginx-ingress-ingress-nginx-controller -- \
  cat /etc/nginx/tls.pem | openssl x509 -noout -subject
```

---

## TROUBLESHOOTING

### 502 Errors
- Check cloudflared logs: `kubectl logs -n cloudflared-data -l app=cloudflared`
- Verify TLS secret exists: `kubectl get secret cloudflare-origin-cert -n ingress-nginx`
- Check NGINX is running: `kubectl get pods -n ingress-nginx`

### TLS Errors
- Verify certificate format: PEM format with valid dates
- Check private key matches certificate
- Verify DNS pointing to correct tunnel

### Redirect Loops
- Ensure Ingress has correct hostname
- Check NGINX redirect settings
- noTLSVerify should be true for self-signed certs

---

## SECURITY BEST PRACTICES

1. ✅ TLS secret in ingress-nginx namespace
2. ✅ RBAC restricts secret access (Role created)
3. ⚠️ Enable encryption at rest: `--encryption-provider-config`
4. ⚠️ Use Sealed Secrets or External Secrets Operator for production
5. ✅ Logging enabled in cloudflared
6. ✅ Liveness/readiness probes configured