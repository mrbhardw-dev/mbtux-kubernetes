# CodeCombat Kubernetes Deployment Guide

Complete deployment guide for CodeCombat (gamified coding education platform) on the mbtux Kubernetes cluster.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Deployment Approach](#deployment-approach)
4. [Option A: Raw Kubernetes Manifests (ArgoCD)](#option-a-raw-kubernetes-manifests-argocd)
5. [Option B: Helm Chart](#option-b-helm-chart)
6. [Configuration Options](#configuration-options)
7. [Post-Deployment Setup](#post-deployment-setup)
8. [Backup and Restore](#backup-and-restore)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
                          +------------------+
                          |   Ingress        |
                          |   (nginx)        |
                          | codecombat.mbtux.com
                          +--------+---------+
                                   |
                          +--------v---------+
                          |   Service        |
                          |   ClusterIP:80   |
                          +--------+---------+
                                   |
                          +--------v---------+
                          |   Deployment     |
                          | codecombat:3000  |
                          | (Node.js app)    |
                          +--------+---------+
                                   |
                          +--------v---------+
                          |   MongoDB        |
                          |   StatefulSet    |
                          |   :27017         |
                          |   (10Gi PVC)     |
                          +------------------+
```

**Components:**
- **CodeCombat**: Node.js application (`codecombat/codecombat:latest`)
- **MongoDB 7.0**: Stateful database with persistent storage (`proxmox-csi`)
- **Nginx Ingress**: External access via `codecombat.mbtux.com`
- **ArgoCD**: GitOps-based continuous deployment

---

## Prerequisites

### Cluster Requirements

| Component | Status | Notes |
|-----------|--------|-------|
| Kubernetes | 1.28+ | Tested on data cluster (3 nodes) |
| kubectl | Configured | `kubectl config use-context data-cluster` |
| ArgoCD | Running | In `argocd` namespace |
| Nginx Ingress | Running | In `ingress-nginx` namespace |
| Proxmox CSI | Running | Storage class `proxmox-csi` available |
| cert-manager | Optional | Required for TLS (not yet deployed) |

### Verify Prerequisites

```bash
# Check kubectl connectivity
kubectl cluster-info

# Verify storage class exists
kubectl get storageclass proxmox-csi

# Verify ingress controller
kubectl get pods -n ingress-nginx

# Verify ArgoCD
kubectl get pods -n argocd
```

### Required Tools (for Helm approach)

```bash
# Install Helm (if not present)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify installation
helm version
```

---

## Deployment Approach

Two deployment options are available:

| Approach | Files | Management | Recommended For |
|----------|-------|------------|-----------------|
| **A: Raw Manifests** | `apps/codecombat/00-*.yaml` through `05-*.yaml` | ArgoCD (current) | Simple deployments, GitOps-first |
| **B: Helm Chart** | `apps/codecombat/helm/codecombat/` | ArgoCD + Helm | Complex config, parameterization |

Both use ArgoCD for GitOps management. **Option A is already deployed and active.**

---

## Option A: Raw Kubernetes Manifests (ArgoCD)

### File Structure

```
apps/codecombat/
├── 00-namespace.yaml           # Namespace + Secret + ConfigMap
├── 01-mongodb-statefulset.yaml # MongoDB PVC + StatefulSet
├── 02-mongodb-service.yaml     # MongoDB ClusterIP service
├── 03-codecombat-deployment.yaml # CodeCombat Deployment
├── 04-codecombat-service.yaml  # CodeCombat ClusterIP service
├── 05-codecombat-ingress.yaml  # Ingress (nginx)
└── argocd-application.yaml     # ArgoCD Application (raw manifests)
```

### Deploy with ArgoCD

The ArgoCD Application is already configured at `apps/codecombat/argocd-application.yaml`:

```yaml
spec:
  source:
    path: apps/codecombat  # Points to raw manifests
  destination:
    namespace: codecombat
```

Apply the ArgoCD Application:

```bash
kubectl apply -f apps/codecombat/argocd-application.yaml -n argocd
```

ArgoCD will automatically sync all manifests in `apps/codecombat/`.

### Deploy Manually (without ArgoCD)

```bash
# Apply in order
kubectl apply -f apps/codecombat/00-namespace.yaml
kubectl apply -f apps/codecombat/01-mongodb-statefulset.yaml
kubectl apply -f apps/codecombat/02-mongodb-service.yaml
kubectl apply -f apps/codecombat/03-codecombat-deployment.yaml
kubectl apply -f apps/codecombat/04-codecombat-service.yaml
kubectl apply -f apps/codecombat/05-codecombat-ingress.yaml
```

### Customizing Raw Manifests

Edit the files directly and commit. ArgoCD will auto-sync:

```bash
# Example: Change replica count
vim apps/codecombat/03-codecombat-deployment.yaml  # Change replicas: 2

# Example: Change storage size
vim apps/codecombat/01-mongodb-statefulset.yaml    # Change storage: 20Gi

# Commit and push
git add -A && git commit -m "scale codecombat to 2 replicas" && git push
```

---

## Option B: Helm Chart

### File Structure

```
apps/codecombat/helm/codecombat/
├── Chart.yaml                  # Chart metadata
├── values.yaml                 # Default configuration
├── .helmignore                 # Files to exclude from packaging
└── templates/
    ├── _helpers.tpl            # Template helpers
    ├── secret.yaml             # MongoDB secrets
    ├── configmap.yaml          # Environment config
    ├── mongodb-statefulset.yaml # MongoDB StatefulSet + PVC
    ├── mongodb-service.yaml    # MongoDB service
    ├── codecombat-deployment.yaml # CodeCombat Deployment
    ├── codecombat-service.yaml # CodeCombat service
    ├── codecombat-ingress.yaml # Ingress configuration
    └── NOTES.txt               # Post-install notes
```

### Deploy with Helm (standalone)

```bash
# Add Bitnami repo (for MongoDB dependency)
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Install the chart
helm install codecombat apps/codecombat/helm/codecombat \
  --namespace codecombat \
  --create-namespace \
  -f apps/codecombat/helm/codecombat/values.yaml

# Verify
helm status codecombat -n codecombat
```

### Deploy with Helm via ArgoCD

The Helm-specific ArgoCD Application is at `apps/codecombat/argocd-application-helm.yaml`:

```yaml
spec:
  source:
    path: apps/codecombat/helm/codecombat  # Points to Helm chart
    helm:
      valueFiles:
        - values.yaml
```

```bash
# Apply the Helm-based ArgoCD app
kubectl apply -f apps/codecombat/argocd-application-helm.yaml -n argocd
```

### Customize Helm Values

Create a `production-values.yaml` override:

```yaml
# production-values.yaml
codecombat:
  replicaCount: 2
  image:
    tag: "v0.1.0"  # Pin to specific version
  resources:
    limits:
      memory: 2Gi
      cpu: "2"

mongodb:
  persistence:
    size: 20Gi

ingress:
  host: "codecombat.mbtux.com"
  tls:
    enabled: true
    clusterIssuer: "letsencrypt-prod"

secrets:
  mongoPassword: "your-secure-production-password"
```

Install with overrides:

```bash
helm upgrade codecombat apps/codecombat/helm/codecombat \
  -f apps/codecombat/helm/codecombat/values.yaml \
  -f production-values.yaml \
  -n codecombat
```

### Template Rendering (Dry Run)

```bash
# Render templates locally without applying
helm template codecombat apps/codecombat/helm/codecombat \
  -f apps/codecombat/helm/codecombat/values.yaml

# Validate
helm lint apps/codecombat/helm/codecombat
```

---

## Configuration Options

### Scaling Replicas

**Raw Manifests:**
```yaml
# apps/codecombat/03-codecombat-deployment.yaml
spec:
  replicas: 3  # Change from 1 to 3
```

**Helm:**
```yaml
# values.yaml
codecombat:
  replicaCount: 3
```

### Custom Domain / DNS

**Raw Manifests:**
```yaml
# apps/codecombat/05-codecombat-ingress.yaml
rules:
  - host: codecombat.school.edu  # Custom domain
```

**Helm:**
```yaml
# values.yaml
ingress:
  host: "codecombat.school.edu"
```

DNS record required:
```
codecombat.school.edu  →  <INGRESS_EXTERNAL_IP>
```

Get ingress IP:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

### SSL/TLS with cert-manager

**Step 1:** Install cert-manager (if not present):

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

**Step 2:** Create a ClusterIssuer:

```yaml
# infrastructure/cert-manager/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@mbtux.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
```

**Step 3:** Enable TLS in ingress:

**Raw Manifests** (`05-codecombat-ingress.yaml`):
```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
    - hosts:
        - codecombat.mbtux.com
      secretName: codecombat-tls
```

**Helm:**
```yaml
# values.yaml
ingress:
  tls:
    enabled: true
    clusterIssuer: "letsencrypt-prod"
    secretName: "codecombat-tls"
```

### Resource Limits

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----------|-------------|-----------|----------------|--------------|
| CodeCombat | 250m | 1 | 512Mi | 1Gi |
| MongoDB | 250m | 1 | 512Mi | 1Gi |

**Adjusting (Helm):**
```yaml
codecombat:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 2Gi

mongodb:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 2Gi
```

### MongoDB Storage Size

**Raw Manifests** (`01-mongodb-statefulset.yaml`):
```yaml
spec:
  resources:
    requests:
      storage: 20Gi  # Change from 10Gi
  storageClassName: proxmox-csi
```

**Helm:**
```yaml
mongodb:
  persistence:
    size: 20Gi
    storageClass: "proxmox-csi"
```

> **Warning:** Increasing PVC size on existing deployments requires storage class support for volume expansion. The `proxmox-csi` class may support this. Decreasing is not supported.

---

## Post-Deployment Setup

### Accessing CodeCombat

**Via Ingress (production):**
```
https://codecombat.mbtux.com
```

**Via Port-Forward (testing):**
```bash
kubectl port-forward -n codecombat svc/codecombat 3000:80
# Open http://localhost:3000
```

### Setting Up Admin Account

1. Navigate to `https://codecombat.mbtux.com`
2. Click **Create Account** / **Sign Up**
3. Register with your admin email
4. Access the admin panel at `https://codecombat.mbtux.com/admin`
5. Configure server settings in the admin dashboard

### Configuring Classroom Features

1. Log in as admin
2. Navigate to **Teachers** section
3. Click **Create a Class**
4. Set class name, language, and course
5. Note the **Class Code** for student enrollment

### Student Enrollment Process

**Option 1: Class Code**
1. Students navigate to `https://codecombat.mbtux.com`
2. Click **Play** then **I have a Class Code**
3. Enter the class code from teacher
4. Create student account

**Option 2: Direct Link**
1. Teacher shares: `https://codecombat.mbtux.com/play?class=<CLASS_ID>`
2. Students create accounts and join automatically

---

## Backup and Restore

### MongoDB Backup

**Manual Backup:**
```bash
# Execute backup inside MongoDB pod
kubectl exec -n codecombat mongodb-0 -- mongodump \
  --username codecombat \
  --password "$MONGO_PASSWORD" \
  --authenticationDatabase admin \
  --db codecombat \
  --out /data/db/backup-$(date +%Y%m%d)

# Copy backup to local machine
kubectl cp codecombat/mongodb-0:/data/db/backup-$(date +%Y%m%d) ./backup-$(date +%Y%m%d)
```

**Automated Backup CronJob:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mongodb-backup
  namespace: codecombat
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: mongo:7.0
              command:
                - sh
                - -c
                - |
                  mongodump --uri="$MONGO_URI" --out=/backup/$(date +%Y%m%d)
              env:
                - name: MONGO_URI
                  valueFrom:
                    secretKeyRef:
                      name: codecombat-secrets
                      key: COCO_MONGO_URL
              volumeMounts:
                - name: backup-storage
                  mountPath: /backup
          restartPolicy: OnFailure
          volumes:
            - name: backup-storage
              persistentVolumeClaim:
                claimName: mongodb-backup-pvc
```

### MongoDB Restore

```bash
# Copy backup to MongoDB pod
kubectl cp ./backup-20240101 codecombat/mongodb-0:/data/db/restore

# Restore database
kubectl exec -n codecombat mongodb-0 -- mongorestore \
  --username codecombat \
  --password "$MONGO_PASSWORD" \
  --authenticationDatabase admin \
  --db codecombat \
  --drop \
  /data/db/restore/codecombat
```

### Full Disaster Recovery

```bash
# 1. Redeploy the stack
kubectl apply -f apps/codecombat/

# 2. Wait for MongoDB to be ready
kubectl wait --for=condition=ready pod/mongodb-0 -n codecombat --timeout=120s

# 3. Restore from backup
kubectl cp ./backup-20240101 codecombat/mongodb-0:/data/db/restore
kubectl exec -n codecombat mongodb-0 -- mongorestore \
  --username codecombat --password "$MONGO_PASSWORD" \
  --authenticationDatabase admin --drop /data/db/restore/codecombat

# 4. Restart CodeCombat to pick up new data
kubectl rollout restart deployment/codecombat -n codecombat
```

---

## Troubleshooting

### CodeCombat Pod CrashLoopBackOff

**Symptoms:** Pod keeps restarting, logs show connection errors.

```bash
# Check pod logs
kubectl logs -n codecombat deployment/codecombat --previous

# Common cause: MongoDB not ready
kubectl get pods -n codecombat
kubectl logs -n codecombat mongodb-0

# Fix: Wait for MongoDB, then restart CodeCombat
kubectl rollout restart deployment/codecombat -n codecombat
```

### MongoDB Connection Refused

**Symptoms:** `COCO_MONGO_URL` connection errors in CodeCombat logs.

```bash
# Verify MongoDB is running
kubectl exec -n codecombat mongodb-0 -- mongosh --eval "db.adminCommand('ping')"

# Check service DNS resolution
kubectl exec -n codecombat deployment/codecombat -- nslookup mongodb

# Verify secret is correct
kubectl get secret codecombat-secrets -n codecombat -o jsonpath='{.data.COCO_MONGO_URL}' | base64 -d
```

### PVC Pending / Storage Issues

**Symptoms:** PVC stuck in `Pending` state.

```bash
# Check PVC status
kubectl get pvc -n codecombat

# Verify storage class exists
kubectl get storageclass

# Check proxmox-csi plugin is running
kubectl get pods -n kube-system -l app=proxmox-csi

# If proxmox-csi is not available, check available storage classes
kubectl get storageclass -o wide
```

### Ingress 502 Bad Gateway

**Symptoms:** Browser shows 502 error when accessing the site.

```bash
# Check CodeCombat service endpoints
kubectl get endpoints codecombat -n codecombat

# Verify CodeCombat pod is running and ready
kubectl get pods -n codecombat -l app=codecombat

# Check ingress configuration
kubectl describe ingress codecombat -n codecombat

# Check ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50
```

### Image Pull Errors

**Symptoms:** `ImagePullBackOff` or `ErrImagePull`.

```bash
# Check pod events
kubectl describe pod -n codecombat -l app=codecombat

# Verify image exists
docker pull codecombat/codecombat:latest

# If using a private registry, check imagePullSecrets
kubectl get secret -n codecombat
```

### MongoDB Data Loss After Pod Restart

**Symptoms:** Database appears empty after restart.

```bash
# Verify PVC is bound and mounted
kubectl describe pvc mongodb-data -n codecombat
kubectl exec -n codecombat mongodb-0 -- df -h /data/db

# Check MongoDB data directory
kubectl exec -n codecombat mongodb-0 -- ls -la /data/db
```

### ArgoCD Sync Failures

```bash
# Check ArgoCD application status
kubectl get application codecombat -n argocd -o yaml

# View sync errors
argocd app get codecombat

# Force sync
argocd app sync codecombat --force
```

### Useful Debug Commands

```bash
# All resources in namespace
kubectl get all -n codecombat

# Resource usage
kubectl top pods -n codecombat

# Events (sorted by time)
kubectl get events -n codecombat --sort-by='.lastTimestamp'

# Full pod description
kubectl describe pod -n codecombat -l app=codecombat

# Shell into CodeCombat pod
kubectl exec -it -n codecombat deployment/codecombat -- sh

# Shell into MongoDB pod
kubectl exec -it -n codecombat mongodb-0 -- mongosh
```

---

## File Reference

| File | Description |
|------|-------------|
| `apps/codecombat/00-namespace.yaml` | Namespace, Secret, ConfigMap |
| `apps/codecombat/01-mongodb-statefulset.yaml` | MongoDB PVC + StatefulSet |
| `apps/codecombat/02-mongodb-service.yaml` | MongoDB ClusterIP service |
| `apps/codecombat/03-codecombat-deployment.yaml` | CodeCombat Deployment |
| `apps/codecombat/04-codecombat-service.yaml` | CodeCombat ClusterIP service |
| `apps/codecombat/05-codecombat-ingress.yaml` | Ingress with nginx |
| `apps/codecombat/argocd-application.yaml` | ArgoCD Application (raw manifests) |
| `apps/codecombat/argocd-application-helm.yaml` | ArgoCD Application (Helm chart) |
| `apps/codecombat/helm/codecombat/` | Helm chart directory |
| `apps/codecombat/helm/codecombat/values.yaml` | Helm default values |
