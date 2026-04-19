# 🚀 Kubernetes GitOps Project-zlSRp3wtrvxGse90

A production-grade GitOps implementation using **Kubernetes**, **ArgoCD**, **Flux**, and **GitHub Actions**. This project demonstrates a full DevOps lifecycle — from infrastructure provisioning to application deployment — using declarative, Git-driven operations.

---

## 📐 Architecture Overview

```
Developer → Git Push → GitHub → CI Pipeline (GitHub Actions)
                                     ↓
                             Build & Test → Push Image → GHCR
                                     ↓
                             Update Manifests → GitOps Repo
                                     ↓
                          ArgoCD / Flux Detects Drift
                                     ↓
                        Kubernetes Cluster Reconciled ✅
```

---

## 🗂️ Project Structure

```
k8s-gitops-project/
├── apps/                        # Application manifests (Kustomize)
│   ├── frontend/
│   │   ├── base/                # Base Kubernetes resources
│   │   └── overlays/            # Environment-specific overrides
│   │       ├── dev/
│   │       ├── staging/
│   │       └── prod/
│   ├── backend/
│   └── database/
├── infrastructure/              # Cluster-level resources
│   ├── namespaces/
│   ├── rbac/
│   ├── monitoring/              # Prometheus + Grafana
│   ├── ingress/                 # NGINX Ingress Controller
│   └── cert-manager/           # TLS certificates
├── gitops/                      # GitOps tooling configs
│   ├── argocd/                  # ArgoCD Applications & Projects
│   └── flux/                    # Flux Kustomizations & Sources
├── ci-cd/                       # CI/CD pipeline definitions
│   ├── github-actions/
│   └── gitlab-ci/
├── scripts/                     # Helper scripts
└── docs/                        # Documentation
```

---

## 🛠️ Tech Stack

| Layer            | Technology                        |
|------------------|-----------------------------------|
| Orchestration    | Kubernetes 1.29+                  |
| GitOps Engine    | ArgoCD 2.10 / Flux v2             |
| Package Manager  | Helm 3.x + Kustomize              |
| CI/CD            | GitHub Actions                    |
| Container Registry | GitHub Container Registry (GHCR) |
| Ingress          | NGINX Ingress Controller          |
| TLS              | cert-manager + Let's Encrypt      |
| Monitoring       | Prometheus + Grafana              |
| Secrets          | Sealed Secrets / External Secrets |
| Service Mesh     | Istio (optional)                  |

---

## 🚀 Quick Start

### Prerequisites
- `kubectl` v1.28+
- `helm` v3.12+
- `kustomize` v5+
- `argocd` CLI
- Access to a Kubernetes cluster (kind/minikube for local)

### 1. Bootstrap ArgoCD
```bash
./scripts/bootstrap-argocd.sh
```

### 2. Apply GitOps Root Application
```bash
kubectl apply -f gitops/argocd/root-app.yaml
```

### 3. Watch Sync
```bash
argocd app list
argocd app sync root-app
```

---

## 🌍 Environments

| Environment | Namespace    | Domain                    | Replicas |
|-------------|--------------|---------------------------|----------|
| dev         | dev          | dev.example.com           | 1        |
| staging     | staging      | staging.example.com       | 2        |
| prod        | production   | example.com               | 3+       |

---

## 📚 Documentation

- [GitOps Workflow](docs/gitops-workflow.md)
- [Environment Setup](docs/environment-setup.md)
- [Secrets Management](docs/secrets-management.md)
- [Monitoring Guide](docs/monitoring.md)
- [Runbook](docs/runbook.md)
