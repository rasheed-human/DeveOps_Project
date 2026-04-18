# Environment Setup Guide

## Local Development (kind / minikube)

### 1. Install Prerequisites

```bash
# macOS
brew install kubectl helm kustomize kind argocd kubeseal jq

# Linux
curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
```

### 2. Create Local Cluster (kind)

```bash
# Create cluster with port mappings for ingress
cat <<EOF | kind create cluster --name gitops-demo --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
EOF

# Verify cluster
kubectl cluster-info --context kind-gitops-demo
kubectl get nodes
```

### 3. Bootstrap the Stack

```bash
# Clone the repo
git clone https://github.com/your-org/k8s-gitops-project.git
cd k8s-gitops-project

# Run bootstrap
chmod +x scripts/bootstrap-argocd.sh
./scripts/bootstrap-argocd.sh

# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
# Open: https://localhost:8080
# User: admin / Password: (shown by bootstrap script)
```

### 4. Install NGINX Ingress (local)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

### 5. Add /etc/hosts entries (local DNS)

```bash
echo "127.0.0.1 dev.example.com api-dev.example.com argocd.example.com" | sudo tee -a /etc/hosts
```

---

## Required GitHub Secrets

Configure these in your GitHub repo → Settings → Secrets:

| Secret | Description |
|--------|-------------|
| `GITOPS_PAT` | GitHub Personal Access Token with `repo` scope (for updating manifests) |
| `ARGOCD_SERVER` | ArgoCD server URL, e.g. `argocd.example.com` |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token (create via ArgoCD UI → User Info → Generate Token) |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook for deploy notifications |
| `CODECOV_TOKEN` | Codecov upload token |
| `SEMGREP_APP_TOKEN` | Semgrep SAST token (optional) |
| `GITLEAKS_LICENSE` | Gitleaks license key (optional, free tier available) |

---

## Required Kubernetes Secrets

These must be created on the cluster before ArgoCD syncs apps:

```bash
# GHCR image pull secret
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<github-pat> \
  --docker-email=<email> \
  -n production

# Git credentials for Flux (if using Flux)
kubectl create secret generic git-credentials \
  --from-literal=username=<github-user> \
  --from-literal=password=<github-pat> \
  -n flux-system

# ArgoCD repo credentials
argocd repo add https://github.com/your-org/k8s-gitops-project.git \
  --username <github-user> \
  --password <github-pat>
```
