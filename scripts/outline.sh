#!/bin/bash
# Outline Kubernetes Deployment Helper Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="outline"
DOMAIN="${1:-outline.mbtux.com}"
EMAIL="${2:-mritunjay.bhardwaj@mbtux.com}"

echo -e "${GREEN}=== Outline Kubernetes Deployment Helper ===${NC}\n"

# Function to print status
status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed"
    exit 1
fi
status "kubectl found"

if ! command -v openssl &> /dev/null; then
    error "openssl is not installed"
    exit 1
fi
status "openssl found"

# Check cluster connection
if ! kubectl cluster-info &> /dev/null; then
    error "Cannot connect to Kubernetes cluster"
    exit 1
fi
status "Connected to Kubernetes cluster"

# Generate secrets
echo -e "\n${YELLOW}Generating security keys...${NC}"
SECRET_KEY=$(openssl rand -hex 32)
UTILS_SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
status "Security keys generated"

# Create namespace
echo -e "\n${YELLOW}Creating namespace...${NC}"
if kubectl get namespace $NAMESPACE &> /dev/null; then
    warning "Namespace $NAMESPACE already exists"
else
    kubectl create namespace $NAMESPACE
    status "Namespace $NAMESPACE created"
fi

# Label namespace for pod security
kubectl label namespace $NAMESPACE pod-security.kubernetes.io/enforce=baseline --overwrite 2>/dev/null || true

# Check for cert-manager
echo -e "\n${YELLOW}Checking for cert-manager...${NC}"
if kubectl get ns cert-manager &> /dev/null; then
    status "cert-manager found"
else
    warning "cert-manager not found. Installing..."
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --wait
    status "cert-manager installed"
fi

# Create ClusterIssuer for Let's Encrypt
echo -e "\n${YELLOW}Setting up Let's Encrypt...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
status "Let's Encrypt ClusterIssuer configured"

# Check for ingress-nginx
echo -e "\n${YELLOW}Checking for ingress-nginx...${NC}"
if kubectl get ns ingress-nginx &> /dev/null; then
    status "ingress-nginx found"
else
    warning "ingress-nginx not found. Installing..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    helm install nginx-ingress ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --wait
    status "ingress-nginx installed"
fi

# Create ConfigMap
echo -e "\n${YELLOW}Creating ConfigMap...${NC}"
kubectl create configmap outline-config \
    --from-literal=NODE_ENV=production \
    --from-literal=FORCE_HTTPS=true \
    --from-literal=LOG_LEVEL=info \
    --from-literal=URL=https://$DOMAIN \
    --from-literal=DATABASE_URL_PROTOCOL=postgres \
    --from-literal=POSTGRES_HOST=outline-postgres \
    --from-literal=POSTGRES_PORT=5432 \
    --from-literal=POSTGRES_DB=outline \
    --from-literal=POSTGRES_USER=outline \
    --from-literal=REDIS_HOST=outline-redis \
    --from-literal=REDIS_PORT=6379 \
    --from-literal=SECRET_KEY=$SECRET_KEY \
    --from-literal=UTILS_SECRET_KEY=$UTILS_SECRET_KEY \
    --from-literal=FILE_STORAGE=local \
    --from-literal=FILE_STORAGE_LOCAL_ROOT_DIR=/data/uploads \
    --from-literal=SMTP_HOST=smtp.example.com \
    --from-literal=SMTP_PORT=587 \
    --from-literal=SMTP_USERNAME=your-email@example.com \
    --from-literal=SMTP_FROM_EMAIL=outline@example.com \
    --from-literal=SMTP_TLS_CIPHERS=DEFAULT \
    --from-literal=SMTP_REPLY_EMAIL=support@example.com \
    --namespace=$NAMESPACE \
    -o yaml | kubectl apply -f -
status "ConfigMap created"

# Create Secret
echo -e "\n${YELLOW}Creating Secret...${NC}"
kubectl create secret generic outline-secrets \
    --from-literal=postgres-password=$POSTGRES_PASSWORD \
    --from-literal=redis-password= \
    --from-literal=smtp-password=your-smtp-password \
    --from-literal=slack-secret= \
    --namespace=$NAMESPACE \
    -o yaml | kubectl apply -f -
status "Secret created"

# Output summary
echo -e "\n${GREEN}=== Deployment Summary ===${NC}"
echo -e "Namespace: ${YELLOW}$NAMESPACE${NC}"
echo -e "Domain: ${YELLOW}$DOMAIN${NC}"
echo -e "Email: ${YELLOW}$EMAIL${NC}"
echo -e "\n${YELLOW}Generated Secrets (save these securely):${NC}"
echo -e "SECRET_KEY: ${RED}$SECRET_KEY${NC}"
echo -e "UTILS_SECRET_KEY: ${RED}$UTILS_SECRET_KEY${NC}"
echo -e "POSTGRES_PASSWORD: ${RED}$POSTGRES_PASSWORD${NC}"

echo -e "\n${YELLOW}Next Steps:${NC}"
echo "1. Update SMTP credentials in the Secret:"
echo "   kubectl edit secret outline-secrets -n $NAMESPACE"
echo ""
echo "2. Update Slack OAuth credentials (optional):"
echo "   kubectl edit secret outline-secrets -n $NAMESPACE"
echo ""
echo "3. Apply the deployment:"
echo "   kubectl apply -f outline-k8s-deployment.yaml"
echo ""
echo "4. Monitor the deployment:"
echo "   kubectl get pods -n $NAMESPACE -w"
echo ""
echo "5. Check ingress status:"
echo "   kubectl get ingress -n $NAMESPACE"
echo ""
echo "6. Access your Outline instance at: https://$DOMAIN"

echo -e "\n${GREEN}Setup complete!${NC}"