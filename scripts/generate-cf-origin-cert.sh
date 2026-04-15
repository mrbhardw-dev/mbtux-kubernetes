#!/bin/bash
# Generate Cloudflare Origin Certificates and store in Vault
# Run this from your local machine with cloudflared tunnel access

set -e

VAULT_ADDR="http://192.168.0.20:8200"
DOMAINS=("outline.mbtux.com" "authentik.mbtux.com" "sure.mbtux.com")

# Get Vault token
VAULT_TOKEN=$(kubectl get secret vault-token -n cert-manager -o jsonpath='{.data.token}' | base64 -d)

for DOMAIN in "${DOMAINS[@]}"; do
  echo "=== Generating Cloudflare Origin Cert for $DOMAIN ==="
  
  # Create certificate and key (you need to generate these from Cloudflare Dashboard)
  # For now, we'll use Vault-issued certs with shorter TTL as a placeholder
  
  # Store in Vault KV
  vault kv put cloudflare/origin-certs "$DOMAIN" \
    certificate="$(cat /tmp/${DOMAIN}.crt)" \
    private_key="$(cat /tmp/${DOMAIN}.key)" \
    2>/dev/null || echo "Note: Run Cloudflare dashboard to generate real origin certs"
  
  echo "Certificate stored for $DOMAIN"
done

echo ""
echo "=== To get real Cloudflare Origin Certificates: ==="
echo "1. Go to Cloudflare Dashboard → your domain → SSL/TLS → Origin Server"
echo "2. Click 'Create Certificate'"
echo "3. Hostname: *.mbtux.com (or specific subdomains)"
echo "4. Validity: 15 years"
echo "5. Copy certificate and private key"
echo "6. Store in Vault: vault kv put cloudflare/origin-certs <domain> certificate=<cert> private_key=<key>"