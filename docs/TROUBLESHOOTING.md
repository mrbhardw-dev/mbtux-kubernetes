# Rancher 2.14.0 Troubleshooting & Validation Guide

## Quick Validation Commands

Run these after deployment to verify all components are healthy.

### Pre-Deployment Validation

```bash
# Verify cluster contexts exist
kubectl config get-contexts

# Verify cluster connectivity
kubectl --context mgmt-cluster cluster-info
kubectl --context data-cluster cluster-info

# Check node status
kubectl --context mgmt-cluster get nodes -o wide
kubectl --context data-cluster get nodes -o wide

# Verify prerequisites
kubectl version --client --short
helm version --short
curl --version | head -1
jq --version

# Check ingress and MetalLB
kubectl --context mgmt-cluster get svc -n ingress-nginx
kubectl --context mgmt-cluster get pods -n metallb-system

# Check cert-manager
kubectl --context mgmt-cluster get clusterissuer

# Check StorageClass
kubectl --context mgmt-cluster get storageclass
```

### Post-Deployment Validation

```bash
# ── Rancher Core ──
kubectl --context mgmt-cluster get pods -n cattle-system
curl -sk https://rancher.mbtux.com/ping
curl -sk https://rancher.mbtux.com/v3/settings/server-version | jq '.value'

# ── Fleet ──
kubectl --context mgmt-cluster get pods -n cattle-fleet-system
kubectl --context mgmt-cluster get gitrepo -A
kubectl --context mgmt-cluster get bundle -A
kubectl --context mgmt-cluster get cluster -n fleet-default

# ── Monitoring ──
kubectl --context mgmt-cluster get pods -n cattle-monitoring-system
kubectl --context mgmt-cluster get svc -n cattle-monitoring-system
curl -sk -u admin:PASSWORD https://grafana.mbtux.com/api/health | jq .

# ── data-cluster ──
kubectl --context mgmt-cluster get clusters.management.cattle.io
kubectl --context data-cluster get pods -n cattle-fleet-system

# ── RBAC ──
kubectl --context mgmt-cluster get clusterroles | grep rancher
kubectl --context mgmt-cluster get clusterrolebindings | grep rancher

# ── Backup ──
kubectl --context mgmt-cluster get cronjob -n cattle-system
```

---

## 5 Common Issues with Solutions

### Issue 1: Rancher Pods Not Starting

**Symptoms:**
- Pods in `CrashLoopBackOff`, `Pending`, or `Error` state
- `kubectl get pods -n cattle-system` shows pods not Running

**Diagnosis:**

```bash
# Check pod status and events
kubectl --context mgmt-cluster describe pods -n cattle-system -l app=rancher

# Check logs
kubectl --context mgmt-cluster logs -n cattle-system -l app=rancher --tail=100

# Check if there are enough resources
kubectl --context mgmt-cluster top nodes
kubectl --context mgmt-cluster get events -n cattle-system --sort-by='.lastTimestamp'

# Check PVC status (if persistence enabled)
kubectl --context mgmt-cluster get pvc -n cattle-system
```

**Common Causes and Fixes:**

1. **Insufficient resources:**
```bash
# Check resource requests vs available
kubectl --context mgmt-cluster describe nodes | grep -A 10 "Allocated resources"
# Fix: Reduce resource requests or add nodes
```

2. **Image pull failure:**
```bash
kubectl --context mgmt-cluster get events -n cattle-system | grep -i pull
# Fix: Verify image registry is accessible
kubectl --context mgmt-cluster get pods -n cattle-system -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}'
```

3. **PVC pending:**
```bash
kubectl --context mgmt-cluster get pvc -n cattle-system
kubectl --context mgmt-cluster describe pvc -n cattle-system
# Fix: Verify StorageClass exists and provisioner is working
kubectl --context mgmt-cluster get storageclass
kubectl --context mgmt-cluster get pods -n kube-system | grep -i csi
```

4. **Secret missing:**
```bash
kubectl --context mgmt-cluster get secret -n cattle-system bootstrap-secret
# Fix: Reinstall Rancher or recreate the secret
helm --kube-context mgmt-cluster uninstall rancher -n cattle-system
# Then reinstall
```

---

### Issue 2: Cannot Access Rancher UI

**Symptoms:**
- Browser shows "Connection refused" or "502 Bad Gateway"
- `curl https://rancher.mbtux.com` fails

**Diagnosis:**

```bash
# Check ingress
kubectl --context mgmt-cluster get ingress -n cattle-system

# Check ingress controller
kubectl --context mgmt-cluster get pods -n ingress-nginx

# Check ingress controller logs
kubectl --context mgmt-cluster logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50

# Check service endpoints
kubectl --context mgmt-cluster get endpoints -n cattle-system

# Check DNS resolution
nslookup rancher.mbtux.com
dig rancher.mbtux.com

# Test with IP directly
curl -sk -H "Host: rancher.mbtux.com" https://192.168.0.210/ping
```

**Common Causes and Fixes:**

1. **DNS not resolving:**
```bash
# Verify DNS record
nslookup rancher.mbtux.com
# Should resolve to 192.168.0.210 (MetalLB IP)
# Fix: Update DNS A record
```

2. **Ingress not configured:**
```bash
kubectl --context mgmt-cluster get ingress -n cattle-system
# If missing, check Rancher values.yaml has ingress.enabled=true
# Fix: helm upgrade rancher --set ingress.enabled=true
```

3. **TLS certificate issue:**
```bash
kubectl --context mgmt-cluster get certificate -n cattle-system
kubectl --context mgmt-cluster describe certificate -n cattle-system
# Fix: Check cert-manager ClusterIssuer
kubectl --context mgmt-cluster get clusterissuer letsencrypt-prod -o yaml
```

4. **MetalLB not allocating IP:**
```bash
kubectl --context mgmt-cluster get svc -n ingress-nginx
# If EXTERNAL-IP is <pending>, MetalLB isn't configured
kubectl --context mgmt-cluster get ipaddresspool -n metallb-system
kubectl --context mgmt-cluster get l2advertisement -n metallb-system
```

---

### Issue 3: GitRepo Sync Failing

**Symptoms:**
- `kubectl get gitrepo` shows `NotReady` or error state
- Fleet bundles not deploying to target clusters

**Diagnosis:**

```bash
# Check GitRepo status
kubectl --context mgmt-cluster get gitrepo -A
kubectl --context mgmt-cluster describe gitrepo -n fleet-local fleet-mgmt

# Check gitjob logs
kubectl --context mgmt-cluster logs -n cattle-fleet-system -l app=gitjob --tail=100

# Check fleet-controller logs
kubectl --context mgmt-cluster logs -n cattle-fleet-system -l app=fleet-controller --tail=100

# Check HTTP basic auth secret
kubectl --context mgmt-cluster get secret git-http-basic-auth -n cattle-fleet-system -o yaml

# Test git clone with the credentials
git clone https://YOUR_USERNAME:YOUR_TOKEN@github.com/mrbhardw-dev/mbtux-kubernetes.git /tmp/test-clone
rm -rf /tmp/test-clone
```

**Common Causes and Fixes:**

1. **Invalid git credentials:**
```bash
# Delete and recreate the secret
kubectl --context mgmt-cluster delete secret git-http-basic-auth -n cattle-fleet-system
kubectl --context mgmt-cluster create secret generic git-http-basic-auth \
  -n cattle-fleet-system \
  --from-literal=username=NEW_USERNAME \
  --from-literal=password=NEW_TOKEN
# Restart gitjob to pick up new credentials
kubectl --context mgmt-cluster rollout restart deployment/gitjob -n cattle-fleet-system
```

2. **Git repo URL incorrect:**
```bash
kubectl --context mgmt-cluster get gitrepo -n fleet-local fleet-mgmt -o jsonpath='{.spec.repo}'
# Fix: Update the repo URL in fleetCD-mgmt/config.yaml and reapply
```

3. **Branch not found:**
```bash
kubectl --context mgmt-cluster get gitrepo -n fleet-local fleet-mgmt -o jsonpath='{.spec.branch}'
# Fix: Verify the branch exists in the repository
git ls-remote --heads https://github.com/mrbhardw-dev/mbtux-kubernetes.git
```

4. **Path not found:**
```bash
kubectl --context mgmt-cluster get gitrepo -n fleet-local fleet-mgmt -o jsonpath='{.spec.paths}'
# Verify the paths exist in the repository
ls -la infrastructure/rancher/
ls -la infrastructure/cloudflared-mgmt/
```

5. **Network connectivity:**
```bash
# Test from within the cluster
kubectl --context mgmt-cluster run git-test --rm -it --image=alpine --restart=Never -- \
  apk add git curl && curl -s https://github.com
```

---

### Issue 4: Applications Not Deploying to Target Cluster

**Symptoms:**
- GitRepo shows Active but bundles not appearing on data-cluster
- Resources created on mgmt-cluster but not on data-cluster

**Diagnosis:**

```bash
# Check Fleet cluster status
kubectl --context mgmt-cluster get cluster -n fleet-default
kubectl --context mgmt-cluster describe cluster -n fleet-default data-cluster

# Check bundle status
kubectl --context mgmt-cluster get bundle -A
kubectl --context mgmt-cluster describe bundle -n fleet-default

# Check Fleet agent on data-cluster
kubectl --context data-cluster get pods -n cattle-fleet-system
kubectl --context data-cluster logs -n cattle-fleet-system -l app=fleet-agent --tail=100

# Check cluster registration
kubectl --context mgmt-cluster get clusters.management.cattle.io
kubectl --context mgmt-cluster get clusterregistrationtokens -n fleet-default
```

**Common Causes and Fixes:**

1. **Fleet agent not running on data-cluster:**
```bash
kubectl --context data-cluster get pods -n cattle-fleet-system
# If not running, re-register the cluster via Rancher UI
# Or apply the fleet agent manifest manually
```

2. **Cluster not in correct Fleet group:**
```bash
kubectl --context mgmt-cluster get clustergroup -n fleet-default
kubectl --context mgmt-cluster describe clustergroup -n fleet-default data-cluster-group
# Fix: Verify labels match the cluster selector
kubectl --context mgmt-cluster get cluster -n fleet-default data-cluster --show-labels
```

3. **Bundle targeting wrong cluster:**
```bash
kubectl --context mgmt-cluster get bundle -A -o yaml | grep -A 5 targets
# Fix: Update targets in the GitRepo configuration
```

4. **Namespace issues on target cluster:**
```bash
kubectl --context data-cluster get namespaces
# If target namespace doesn't exist and CreateNamespace isn't set
# Fix: Ensure correctDrift is enabled or create namespace manually
```

---

### Issue 5: High CPU/Memory Usage

**Symptoms:**
- Pods being OOMKilled
- Nodes showing high resource utilization
- Slow UI response

**Diagnosis:**

```bash
# Check resource usage
kubectl --context mgmt-cluster top pods -n cattle-system --sort-by=memory
kubectl --context mgmt-cluster top pods -n cattle-monitoring-system --sort-by=memory
kubectl --context mgmt-cluster top nodes

# Check resource limits
kubectl --context mgmt-cluster get pods -n cattle-system -o json | jq '.items[] | {name: .metadata.name, requests: .spec.containers[0].resources.requests, limits: .spec.containers[0].resources.limits}'

# Check for memory leaks
kubectl --context mgmt-cluster logs -n cattle-system -l app=rancher --tail=100 | grep -i "memory\|oom\|killed"

# Check HPA status (if configured)
kubectl --context mgmt-cluster get hpa -A

# Check Prometheus memory
kubectl --context mgmt-cluster exec -n cattle-monitoring-system -it prometheus-monitoring-kube-prometheus-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/status/tsdb | jq .
```

**Common Causes and Fixes:**

1. **Prometheus using too much memory:**
```bash
# Reduce retention period
helm --kube-context mgmt-cluster upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n cattle-monitoring-system \
  --set prometheus.prometheusSpec.retention=7d \
  --reuse-values

# Reduce scrape interval
# Edit Prometheus config to increase scrape_interval from 15s to 30s
```

2. **Rancher server memory limit too low:**
```bash
# Increase limits
helm --kube-context mgmt-cluster upgrade rancher rancher-stable/rancher \
  -n cattle-system \
  --set resources.limits.cpu=2 \
  --set resources.limits.memory=2Gi \
  --reuse-values
```

3. **Too many monitoring targets:**
```bash
kubectl --context mgmt-cluster get servicemonitors -A | wc -l
kubectl --context mgmt-cluster get podmonitors -A | wc -l
# Fix: Remove unnecessary ServiceMonitors/PodMonitors
```

4. **Grafana dashboard queries too expensive:**
```bash
# Check slow queries in Grafana
curl -s -u admin:PASSWORD https://grafana.mbtux.com/api/datasources/proxy/1/api/v1/query?query=up | jq .
# Fix: Optimize dashboard queries or add recording rules
```

---

## Advanced Troubleshooting

### Network Debugging

```bash
# Test pod-to-pod connectivity
kubectl --context mgmt-cluster run nettest --rm -it --image=busybox --restart=Never -- \
  wget -qO- http://rancher.cattle-system.svc.cluster.local/ping

# Check CoreDNS resolution
kubectl --context mgmt-cluster run dnstest --rm -it --image=busybox --restart=Never -- \
  nslookup rancher.cattle-system.svc.cluster.local

# Check network policies
kubectl --context mgmt-cluster get networkpolicies -A

# Check service endpoints
kubectl --context mgmt-cluster get endpoints -n cattle-system

# Trace network path
kubectl --context mgmt-cluster run traceroute --rm -it --image=busybox --restart=Never -- \
  traceroute 192.168.0.210

# Check iptables rules on nodes
ssh rancher@192.168.0.201 "sudo iptables -t nat -L -n | grep -i rancher"

# Check MetalLB speaker logs
kubectl --context mgmt-cluster logs -n metallb-system -l app=metallb,component=speaker --tail=50
```

### Certificate Debugging

```bash
# Check certificate status
kubectl --context mgmt-cluster get certificates -A
kubectl --context mgmt-cluster get certificaterequests -A
kubectl --context mgmt-cluster get orders.acme -A
kubectl --context mgmt-cluster get challenges.acme -A

# Check certificate details
kubectl --context mgmt-cluster describe certificate -n cattle-system

# Check cert-manager logs
kubectl --context mgmt-cluster logs -n cert-manager -l app=cert-manager --tail=100

# Verify certificate in secret
kubectl --context mgmt-cluster get secret -n cattle-system -l cert-manager.io/certificate-name -o yaml

# Check Let's Encrypt rate limits
# Visit: https://crt.sh/?q=rancher.mbtux.com

# Verify TLS from client
openssl s_client -connect rancher.mbtux.com:443 -servername rancher.mbtux.com </dev/null 2>/dev/null | \
  openssl x509 -noout -dates -subject

# Check ClusterIssuer
kubectl --context mgmt-cluster get clusterissuer letsencrypt-prod -o yaml
kubectl --context mgmt-cluster describe clusterissuer letsencrypt-prod
```

### Performance Tuning

```bash
# ── Rancher Server ──
# Increase replicas for HA
helm --kube-context mgmt-cluster upgrade rancher rancher-stable/rancher \
  -n cattle-system \
  --set replicas=3 \
  --reuse-values

# Tune resource limits
helm --kube-context mgmt-cluster upgrade rancher rancher-stable/rancher \
  -n cattle-system \
  --set resources.requests.cpu=500m \
  --set resources.requests.memory=1Gi \
  --set resources.limits.cpu=2 \
  --set resources.limits.memory=2Gi \
  --reuse-values

# ── Prometheus ──
# Reduce scrape targets
kubectl --context mgmt-cluster get servicemonitors -A -o json | \
  jq '.items[] | select(.spec.endpoints[0].scrapeInterval == "15s") | .metadata.name'

# Add recording rules for expensive queries
kubectl --context mgmt-cluster apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rancher-recording-rules
  namespace: cattle-monitoring-system
spec:
  groups:
    - name: rancher.rules
      rules:
        - record: rancher:cluster_cpu_usage:sum
          expr: sum(rate(container_cpu_usage_seconds_total{namespace=~"cattle-.*"}[5m]))
        - record: rancher:cluster_memory_usage:sum
          expr: sum(container_memory_working_set_bytes{namespace=~"cattle-.*"})
EOF

# ── Fleet ──
# Increase polling interval if too frequent
kubectl --context mgmt-cluster patch gitrepo -n fleet-local fleet-mgmt \
  --type merge -p '{"spec":{"pollingInterval":"120s"}}'

# ── etcd ──
# Compact etcd (run on control plane node)
ssh rancher@192.168.0.201 "sudo rke2 etcd-snapshot save"
ssh rancher@192.168.0.201 "sudo rke2 etcd-defrag"
```

### Backup & Recovery Procedures

#### Create Manual Backup

```bash
# Method 1: etcd snapshot
ssh rancher@192.168.0.201 "sudo rke2 etcd-snapshot save --name manual-$(date +%Y%m%d-%H%M%S)"

# Method 2: Rancher backup via API
RANCHER_TOKEN="token-xxxxx:YOUR_TOKEN"
curl -sk -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  "https://rancher.mbtux.com/v3/clusterBackups" \
  -H 'Content-Type: application/json' \
  -d '{"clusterId":"local","manual":true,"filename":"manual-backup"}'

# Method 3: Export all resources
kubectl --context mgmt-cluster get -A -o yaml all > /tmp/all-resources-backup.yaml
kubectl --context mgmt-cluster get -A -o yaml secrets > /tmp/secrets-backup.yaml
kubectl --context mgmt-cluster get -A -o yaml configmaps > /tmp/configmaps-backup.yaml
```

#### List Backups

```bash
# etcd snapshots
ssh rancher@192.168.0.201 "sudo rke2 etcd-snapshot list"

# Rancher backups via API
curl -sk -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  "https://rancher.mbtux.com/v3/clusterBackups" | jq '.data[] | {name: .name, created: .created}'

# CronJob backup history
kubectl --context mgmt-cluster get jobs -n cattle-system -l job-name=rancher-backup
```

#### Restore from Backup

```bash
# Step 1: Stop Rancher
helm --kube-context mgmt-cluster uninstall rancher -n cattle-system

# Step 2: Restore etcd (on control plane node)
ssh rancher@192.168.0.201 "sudo rke2 etcd-snapshot restore /var/lib/rancher/rke2/server/db/snapshots/manual-backup"

# Step 3: Restart RKE2
ssh rancher@192.168.0.201 "sudo systemctl restart rke2-server"

# Step 4: Reinstall Rancher
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --version 2.14.0 \
  --set hostname=rancher.mbtux.com \
  --set replicas=3 \
  # ... (same values as original install)

# Step 5: Verify restoration
kubectl --context mgmt-cluster get clusters.management.cattle.io
curl -sk https://rancher.mbtux.com/ping
```

#### Disaster Recovery

```bash
# Complete cluster recovery procedure

# 1. On new mgmt-cluster control plane, install RKE2
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.31.14+rke2r1 sh -
systemctl enable rke2-server && systemctl start rke2-server

# 2. Copy kubeconfig
mkdir -p ~/.kube
cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
chmod 600 ~/.kube/config

# 3. Add context
kubectl config set-context mgmt-cluster --cluster=default --user=default

# 4. Restore etcd from backup
rke2 server --cluster-reset --cluster-reset-restore-path=/path/to/backup

# 5. Restart RKE2
systemctl restart rke2-server

# 6. Verify nodes
kubectl get nodes

# 7. Reinstall components following the deployment guide
```

---

## Quick Commands Reference

### Rancher Management

```bash
# Rancher status
kubectl get pods -n cattle-system
curl -sk https://rancher.mbtux.com/ping

# Rancher version
curl -sk https://rancher.mbtux.com/v3/settings/server-version | jq '.value'

# Rancher logs
kubectl logs -n cattle-system -l app=rancher --tail=100 -f

# Rancher restart (rolling)
kubectl rollout restart deployment/rancher -n cattle-system

# Rancher upgrade
helm upgrade rancher rancher-stable/rancher -n cattle-system --version 2.14.0 --reuse-values

# Get bootstrap password
kubectl get secret --namespace cattle-system bootstrap-secret -o goop='{.data.bootstrapPassword}' | base64 --decode; echo
```

### Fleet Management

```bash
# Fleet status
kubectl get gitrepo -A
kubectl get bundle -A
kubectl get cluster -n fleet-default

# Fleet logs
kubectl logs -n cattle-fleet-system -l app=fleet-controller --tail=100 -f
kubectl logs -n cattle-fleet-system -l app=gitjob --tail=100 -f

# Force sync a GitRepo
kubectl patch gitrepo -n fleet-local fleet-mgmt --type merge -p '{"spec":{"forceSyncGeneration":1}}'

# Restart Fleet controller
kubectl rollout restart deployment/fleet-controller -n cattle-fleet-system

# Check drift
kubectl get bundle -n fleet-local -o json | jq '.items[] | {name: .metadata.name, ready: .status.conditions[?(@.type=="Ready")].status}'
```

### Monitoring

```bash
# Prometheus status
kubectl get pods -n cattle-monitoring-system -l app.kubernetes.io/name=prometheus

# Prometheus targets
kubectl port-forward -n cattle-monitoring-system svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'

# Prometheus metrics query
curl -s http://localhost:9090/api/v1/query?query=up | jq '.data.result | length'

# Grafana health
curl -s -u admin:PASSWORD https://grafana.mbtux.com/api/health | jq .

# AlertManager status
kubectl get pods -n cattle-monitoring-system -l app.kubernetes.io/name=alertmanager

# Restart monitoring stack
kubectl rollout restart statefulset/prometheus-monitoring-kube-prometheus-prometheus -n cattle-monitoring-system
kubectl rollout restart statefulset/alertmanager-monitoring-kube-prometheus-alertmanager -n cattle-monitoring-system
kubectl rollout restart deployment/monitoring-grafana -n cattle-monitoring-system
```

### RBAC

```bash
# List Rancher roles
kubectl get clusterroles | grep rancher
kubectl get clusterrolebindings | grep rancher

# Test permissions
kubectl auth can-i get gitrepos.fleet.cattle.io --as=system:serviceaccount:cattle-fleet-system:default
kubectl auth can-i '*' '*' --as=system:serviceaccount:cattle-system:rancher

# Create a test user
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-user
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: test-user-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rancher-cluster-viewer
subjects:
  - kind: ServiceAccount
    name: test-user
    namespace: default
EOF
```

### Network Debugging

```bash
# DNS
nslookup rancher.mbtux.com
dig rancher.mbtux.com

# Connectivity
curl -sk https://rancher.mbtux.com/ping
curl -sk -H "Host: rancher.mbtux.com" https://192.168.0.210/ping

# Ingress
kubectl get ingress -A
kubectl describe ingress -n cattle-system rancher

# Services
kubectl get svc -A | grep -E "rancher|ingress"

# Endpoints
kubectl get endpoints -n cattle-system

# MetalLB
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
kubectl logs -n metallb-system -l component=speaker --tail=20
```

### etcd Management

```bash
# List snapshots
rke2 etcd-snapshot list

# Create snapshot
rke2 etcd-snapshot save --name manual-$(date +%Y%m%d)

# Defragment
rke2 etcd-defrag

# Check etcd health
ETCDCTL_API=3 etcdctl endpoint health \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key
```

### Cleanup (Emergency)

```bash
# Remove Rancher completely
helm uninstall rancher -n cattle-system
kubectl delete namespace cattle-system
kubectl delete namespace cattle-fleet-system
kubectl delete namespace cattle-monitoring-system
kubectl delete namespace cattle-dashboards
kubectl delete clusterroles rancher-cluster-viewer rancher-cluster-admin rancher-fleet-manager
kubectl delete clusterrolebindings rancher-admin-binding rancher-viewer-binding rancher-fleet-manager-binding

# Remove Fleet resources
kubectl delete gitrepo -A --all
kubectl delete bundle -A --all
kubectl delete cluster -n fleet-default --all

# Remove CRDs (careful - this removes all custom resources)
kubectl get crds | grep -E "cattle|rancher|fleet" | xargs kubectl delete crd
```
