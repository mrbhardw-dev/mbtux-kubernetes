#!/usr/bin/env bash
set -euo pipefail

auth_dir="${HOME}/.kube/mbtux-auth"
exec_info="${KUBERNETES_EXEC_INFO:-}"

if [[ "$exec_info" == *"192.168.0.201:6443"* ]]; then
  cluster="mgmt"
elif [[ "$exec_info" == *"192.168.0.211:6443"* ]]; then
  cluster="data"
else
  echo "unknown mbtux cluster in KUBERNETES_EXEC_INFO" >&2
  exit 1
fi

cert_file="${auth_dir}/${cluster}.client.crt.b64"
key_file="${auth_dir}/${cluster}.client.key.b64"

if [[ ! -r "$cert_file" || ! -r "$key_file" ]]; then
  echo "missing mbtux auth material for ${cluster}" >&2
  exit 1
fi

jq -n \
  --rawfile cert <(base64 --decode < "$cert_file") \
  --rawfile key <(base64 --decode < "$key_file") \
  '{
    apiVersion: "client.authentication.k8s.io/v1",
    kind: "ExecCredential",
    status: {
      clientCertificateData: $cert,
      clientKeyData: $key
    }
  }'
