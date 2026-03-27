#!/bin/bash
# Run this on the MANAGEMENT CLUSTER to generate Argo CD credentials.
# Outputs the API server URL and bearer token for the cluster secret.

set -euo pipefail

echo "=== Step 1: Create ServiceAccount and RBAC ==="

kubectl create namespace argocd 2>/dev/null || true

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: argocd
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: argocd
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

echo "Waiting for token to be generated..."
sleep 3

echo ""
echo "=== Step 2: Retrieve credentials ==="

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
TOKEN=$(kubectl -n argocd get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n argocd get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')

echo ""
echo "=== Add these to infrastructure/argocd-data/cluster-secret.yaml ==="
echo ""
echo "server: \"${SERVER}\""
echo ""
echo "bearerToken: \"${TOKEN}\""
echo ""
echo "caData: \"${CA}\""
