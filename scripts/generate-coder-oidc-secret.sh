#!/bin/bash
# Helper script to generate OIDC secret values for Coder Authentik integration
# Run this AFTER you have created the OIDC provider in Authentik and have:
# - Client ID
# - Client Secret
# - Provider URL (e.g., https://authentik.mbtux.com/application/o/coder/)

set -e

echo "=========================================="
echo "Coder OIDC Secret Generator"
echo "=========================================="
echo ""

# Check if values are provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <client-id> <client-secret>"
    echo ""
    echo "Example:"
    echo "  $0 PoOCe0BqTr6VaBHoWVRcwLesADWeaYH7gh0JuBdp 'm0PHV2PpWtbR1WYuTOC0QTyGwxDhZ8H1D7MXmVxQaxFoUztSWr9iU1dOcNfuJqCokKra0D6VwYJ4GpZMrPz4Z36d1wmdEtqtkKFMsFbm3ty1vdeaLameIycHSApBZKOu'"
    echo ""
    echo "Will output Kubernetes secret YAML with base64-encoded values."
    exit 1
fi

CLIENT_ID="$1"
CLIENT_SECRET="$2"

# Encode to base64 (no newlines)
CLIENT_ID_B64=$(echo -n "$CLIENT_ID" | base64 -w0 2>/dev/null || echo -n "$CLIENT_ID" | base64)
CLIENT_SECRET_B64=$(echo -n "$CLIENT_SECRET" | base64 -w0 2>/dev/null || echo -n "$CLIENT_SECRET" | base64)

# Generate the secret YAML
cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: authentik-oidc-client
  namespace: coder
type: Opaque
data:
  client-id: ${CLIENT_ID_B64}
  client-secret: ${CLIENT_SECRET_B64}
EOF

echo ""
echo "=========================================="
echo "Secret generated successfully!"
echo "=========================================="
echo ""
echo "To apply this secret to your cluster:"
echo "  kubectl apply -f <(./generate-oidc-secret.sh '<client-id>' '<client-secret>')"
echo ""
echo "Or save to file and apply:"
echo "  ./generate-oidc-secret.sh '<client-id>' '<client-secret>' > oidc-secret.yaml"
echo "  kubectl apply -f oidc-secret.yaml"
echo ""
echo "Make sure to also update coder-auth ConfigMap with your OIDC client ID:"
echo "  production-infrastructure/coder/manifests/03-auth.yaml"
echo "  (field: AUTH_OIDC_CLIENT_ID)"
echo ""
