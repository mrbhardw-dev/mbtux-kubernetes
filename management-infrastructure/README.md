# Management Infrastructure Bootstrap

## Assumptions

1. **Kubernetes Access**: The user has SSH access to the management cluster at `192.168.0.201` with the key `cluster_key`
2. **kubectl configured**: The kubeconfig is properly configured to point to the management cluster
3. **Helm 3.x installed**: Helm 3 or later is installed on the machine running these commands
4. **Argo CD CLI installed**: The argocd CLI is available for cluster registration and verification
5. **HTTPS endpoint**: The domain `argocd-mgmt.mbtux.com` resolves to the LoadBalancer IP
6. **Git repository**: The bootstrap Git repository is `https://github.com/mrbhardw-dev/mbtux-kubernetes`

## Cluster Server URLs

- Management (in-cluster): `https://kubernetes.default.svc` or `https://192.168.0.211:6443`
- prod-eu: `https://192.168.0.212:6443`
- prod-us: `https://192.168.0.213:6443`

---

## Phase 1: Install Platform Dependencies

### 1.1 Install cert-manager

```bash
# Add Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.0 \
  -f management-infrastructure/cert-manager/values.yaml
```

### 1.2 Apply ClusterIssuer

```bash
# Apply the Let's Encrypt ClusterIssuer
kubectl apply -f management-infrastructure/cert-manager/cluster-issuer.yaml
```

### 1.3 Verify cert-manager

```bash
# Check cert-manager pods
kubectl get pods -n cert-manager

# Check ClusterIssuer
kubectl get clusterissuer letsencrypt-prod
```

---

## Phase 2: Install Ingress Controller

### 2.1 Install ingress-nginx

```bash
# Add ingress-nginx Helm repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f management-infrastructure/ingress-nginx/values.yaml
```

### 2.2 Verify ingress-nginx

```bash
# Check ingress-nginx pods
kubectl get pods -n ingress-nginx

# Get LoadBalancer IP
kubectl get svc -n ingress-nginx
```

---

## Phase 3: Install Argo CD

### 3.1 Install Argo CD

```bash
# Add Argo CD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install Argo CD
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 7.4.0 \
  -f management-infrastructure/argocd/values.yaml
```

### 3.2 Verify Argo CD

```bash
# Check Argo CD pods
kubectl get pods -n argocd

# Check ingress
kubectl get ingress -n argocd

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## Phase 4: Create Cluster Service Account

### 4.1 Create Service Account for Remote Clusters

```bash
# Apply the cluster manager service account
kubectl apply -f management-infrastructure/clusters/service-account.yaml
```

### 4.2 Get Token for Remote Cluster Registration

```bash
# Get the service account token (run on remote cluster)
kubectl get secret -n argocd $(kubectl get serviceaccount argocd-cluster-manager -n argocd -o jsonpath='{.secrets[0].name}') -o jsonpath='{.data.token}' | base64 -d
```

---

## Phase 5: Register Spoke Clusters

### 5.1 Register Clusters with Argo CD

```bash
# Login to ArgoCD
argocd login argocd-mgmt.mbtux.com --username admin --password <password> --grpc-web


# Register prod-eu cluster (using kubeconfig)
argocd cluster add <kubeconfig-context> --name prod-eu

# Register prod-us cluster (using kubeconfig)
argocd cluster add <kubeconfig-context> --name prod-us
```

### 5.2 Alternative: Using Secrets

```bash
# Apply cluster secrets
kubectl apply -f management-infrastructure/clusters/manifests/prod-eu.yaml
kubectl apply -f management-infrastructure/clusters/manifests/prod-us.yaml
```

### 5.3 Verify Clusters

```bash
# List registered clusters
argocd cluster list
```

---

## Phase 6: Bootstrap GitOps

### 6.1 Apply AppProject and Root Application

```bash
# Apply the AppProject
kubectl apply -f management-infrastructure/bootstrap/app-project.yaml

# Apply the root bootstrap Application
kubectl apply -f management-infrastructure/bootstrap/root-app.yaml
```

### 6.2 Verify Bootstrap

```bash
# List all applications
argocd app list

# Sync all applications
argocd app sync --all

# Check application health
argocd app get platform-bootstrap
```

---

## Verification Commands

```bash
# Check all pods in system namespaces
kubectl get pods -n cert-manager,ingress-nginx,argocd

# Check cluster list
argocd cluster list

# Check application status
argocd app list

# View application logs
argocd app logs platform-bootstrap

# Check sync status
argocd app sync --all
```

---

## Post-Bootstrap: No Manual kubectl

After bootstrap, all changes should flow through Git:

1. **Add new application**: Create Argo CD Application in `management-infrastructure/bootstrap/apps/`
2. **Add new cluster**: Add cluster secret in `management-infrastructure/clusters/manifests/`
3. **Modify existing**: Update Helm values or manifests in the Git repository

---

## Troubleshooting

### Check Argo CD Logs

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

### Check Application Sync Issues

```bash
argocd app get <app-name> --refresh
argocd app history <app-name>
```

### Reset Admin Password

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
argocd admin init -n argocd
```