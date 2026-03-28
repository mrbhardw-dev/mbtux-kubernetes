#!/bin/bash
# Import data cluster into Rancher Fleet
# Run this AFTER Rancher is deployed and accessible at rancher.mbtux.com
#
# Usage:
#   1. First, get the import command from Rancher UI:
#      - Go to Cluster Management -> Import Existing
#      - Select "Generic" cluster
#      - Copy the import command
#   2. Run the import command on the data cluster
#
# Alternatively, use this script to automate the import:

set -euo pipefail

RANCHER_URL="${RANCHER_URL:-https://rancher.mbtux.com}"
DATA_CLUSTER_CONTEXT="data-context"

echo "=== Data Cluster Import Script ==="
echo ""
echo "Prerequisites:"
echo "  1. Rancher must be deployed and accessible at ${RANCHER_URL}"
echo "  2. You must have the Rancher bootstrap password"
echo "  3. kubectl must have access to both mgmt-context and data-context"
echo ""

# Check if Rancher is accessible
echo "Checking Rancher availability..."
if ! curl -sk "${RANCHER_URL}/ping" > /dev/null 2>&1; then
    echo "ERROR: Rancher is not accessible at ${RANCHER_URL}"
    echo "Please deploy Rancher first and ensure it is running."
    exit 1
fi

echo "Rancher is accessible."
echo ""
echo "To import the data cluster:"
echo ""
echo "1. Log into Rancher at ${RANCHER_URL}"
echo "2. Go to Cluster Management -> Import Existing"
echo "3. Select 'Generic' cluster type"
echo "4. Name the cluster 'mbtux-data-cluster'"
echo "5. Copy the generated import command"
echo "6. Run the import command with: --context ${DATA_CLUSTER_CONTEXT}"
echo ""
echo "Example:"
echo "  curl --insecure -sfL <import-url> | kubectl apply --context ${DATA_CLUSTER_CONTEXT} -f -"
echo ""
echo "After import, the data cluster should appear in Rancher within 1-2 minutes."
echo "Fleet will automatically sync the cluster configuration."
