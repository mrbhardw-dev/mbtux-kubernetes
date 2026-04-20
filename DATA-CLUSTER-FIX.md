# Data Cluster Connection Fix for ArgoCD

## The Issue
```
error getting cluster: error getting cluster RESTConfig: unable to apply K8s REST config defaults: specifying a root certificates file with the insecure flag is not allowed
```

## Solution - Generate New Certificates

**On Data Cluster**, generate a kubeconfig WITHOUT `insecure-skip-tls-verify`:

### Option 1: Get Certs from Data Cluster API Server
```bash
# On data cluster master node or any machine with kubectl access:
openssl s_client -connect 192.168.0.211:6443 -showcerts </dev/null 2>/dev/null | openssl x509 -outform PEM > /tmp/ca.crt

# Create kubeconfig with CA:
kubectl config set-cluster data-cluster \
  --server=https://192.168.0.211:6443 \
  --certificate-authority=/tmp/ca.crt

# Add credentials (use your client cert/key from existing kubeconfig)
kubectl config set-credentials data-user \
  --client-certificate=/path/to/client.crt \
  --client-key=/path/to/client.key
kubectl config set-context data-cluster --cluster=data-cluster --user=data-user
```

### Option 2: Get Fresh Client Certs from Data Cluster CA

1. **On data cluster** - Create service account for ArgoCD:
```bash
kubectl create serviceaccount argocd-manager -n kube-system
kubectl create clusterrolebinding argocd-manager --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager

# Get the token:
kubectl get secret -n kube-system -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="argocd-manager")].data.token}' | base64 -d
```

2. **Use service account token** in kubeconfig instead of client certs

## Current Workaround
All apps are currently deployed to **mgmt cluster**.
To enable data cluster, fix the cluster connection as above, then update the target server in the application manifests.