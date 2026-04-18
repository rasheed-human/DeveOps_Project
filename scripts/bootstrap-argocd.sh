#!/usr/bin/env bash
# ==============================================================
# bootstrap-argocd.sh — Install and configure ArgoCD
# Usage: ./scripts/bootstrap-argocd.sh [--cluster-name NAME]
# ==============================================================

set -euo pipefail

# ---- Config ----
ARGOCD_VERSION="v2.10.3"
ARGOCD_NAMESPACE="argocd"
CLUSTER_NAME="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +'%T')] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%T')] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +'%T')] ❌ $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}[$(date +'%T')] ℹ️  $*${NC}"; }

# ---- Check prerequisites ----
check_prerequisites() {
  info "Checking prerequisites..."
  local missing=()

  for cmd in kubectl helm curl jq; do
    if ! command -v $cmd &>/dev/null; then
      missing+=($cmd)
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
  fi

  # Check cluster connectivity
  if ! kubectl cluster-info &>/dev/null; then
    err "Cannot connect to Kubernetes cluster. Check your kubeconfig."
  fi

  CONTEXT=$(kubectl config current-context)
  info "Connected to cluster: $CONTEXT"

  # Safety check for production
  if [[ "$CONTEXT" == *"prod"* ]]; then
    warn "You are targeting a PRODUCTION cluster: $CONTEXT"
    read -rp "Are you sure? (type 'yes' to continue): " confirm
    [[ "$confirm" == "yes" ]] || err "Aborted."
  fi

  log "Prerequisites satisfied"
}

# ---- Install ArgoCD ----
install_argocd() {
  info "Installing ArgoCD $ARGOCD_VERSION..."

  # Create namespace
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Install ArgoCD
  kubectl apply -n "$ARGOCD_NAMESPACE" \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

  # Wait for ArgoCD to be ready
  info "Waiting for ArgoCD pods to be ready (this may take 2-3 minutes)..."
  kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=300s
  kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=300s
  kubectl rollout status deployment/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=300s

  log "ArgoCD installed successfully"
}

# ---- Configure ArgoCD ----
configure_argocd() {
  info "Configuring ArgoCD..."

  # Patch ArgoCD to disable TLS (for ingress termination)
  kubectl patch configmap argocd-cmd-params-cm \
    -n "$ARGOCD_NAMESPACE" \
    --type merge \
    -p '{"data":{"server.insecure":"true"}}'

  # Apply custom ArgoCD config
  kubectl apply -f "$PROJECT_ROOT/gitops/argocd/argocd-configmap.yaml" || true

  # Restart server to apply config
  kubectl rollout restart deployment/argocd-server -n "$ARGOCD_NAMESPACE"
  kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=120s

  log "ArgoCD configured"
}

# ---- Get admin password ----
get_admin_password() {
  info "Retrieving admin password..."
  local password
  password=$(kubectl get secret argocd-initial-admin-secret \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath="{.data.password}" | base64 -d)

  echo ""
  echo "=============================="
  echo "  ArgoCD Admin Credentials"
  echo "=============================="
  echo "  Username: admin"
  echo "  Password: $password"
  echo "=============================="
  echo ""
  warn "Change this password immediately after first login!"

  # Save to temp file
  echo "$password" > /tmp/argocd-admin-password
  info "Password saved to /tmp/argocd-admin-password (delete after use)"
}

# ---- Install ArgoCD CLI ----
install_cli() {
  if command -v argocd &>/dev/null; then
    info "ArgoCD CLI already installed: $(argocd version --client --short 2>/dev/null)"
    return
  fi

  info "Installing ArgoCD CLI $ARGOCD_VERSION..."
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="amd64"
  [[ "$arch" == "aarch64" ]] && arch="arm64"

  curl -sSL -o /tmp/argocd \
    "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-${os}-${arch}"
  chmod +x /tmp/argocd
  sudo mv /tmp/argocd /usr/local/bin/argocd

  log "ArgoCD CLI installed: $(argocd version --client --short 2>/dev/null)"
}

# ---- Apply project and app configs ----
apply_configs() {
  info "Applying ArgoCD project and application configs..."

  # Port-forward for CLI access
  kubectl port-forward svc/argocd-server -n "$ARGOCD_NAMESPACE" 8080:443 &
  PF_PID=$!
  sleep 3

  # Login
  PASSWORD=$(cat /tmp/argocd-admin-password)
  argocd login localhost:8080 \
    --username admin \
    --password "$PASSWORD" \
    --insecure

  # Apply AppProject and root application
  kubectl apply -f "$PROJECT_ROOT/gitops/argocd/applications.yaml"

  # Sync root app
  argocd app sync root-app --insecure --timeout 120 || true

  # Cleanup port-forward
  kill $PF_PID 2>/dev/null || true

  log "ArgoCD project and applications configured"
}

# ---- Setup ingress for ArgoCD UI ----
setup_ingress() {
  info "Setting up ArgoCD ingress..."

  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: $ARGOCD_NAMESPACE
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - argocd.example.com
    secretName: argocd-tls
  rules:
  - host: argocd.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              name: http
EOF

  log "ArgoCD ingress configured at: https://argocd.example.com"
}

# ---- Main ----
main() {
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║   🚀 ArgoCD Bootstrap Script             ║"
  echo "║   Kubernetes GitOps Project              ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  check_prerequisites
  install_cli
  install_argocd
  configure_argocd
  get_admin_password
  apply_configs
  setup_ingress

  echo ""
  log "Bootstrap complete!"
  info "ArgoCD UI: https://argocd.example.com"
  info "ArgoCD UI (port-forward): kubectl port-forward svc/argocd-server -n argocd 8080:443"
  echo ""
  echo "  Next steps:"
  echo "  1. Log in at https://argocd.example.com"
  echo "  2. Change the admin password"
  echo "  3. Add your Git repo credentials"
  echo "  4. Watch the apps sync: argocd app list"
  echo ""
}

main "$@"
