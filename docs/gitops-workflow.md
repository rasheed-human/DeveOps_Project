# GitOps Workflow — Developer Guide

## Table of Contents
1. [What is GitOps?](#what-is-gitops)
2. [Core Principles](#core-principles)
3. [Workflow Overview](#workflow-overview)
4. [Branch Strategy](#branch-strategy)
5. [How a Deploy Happens](#how-a-deploy-happens)
6. [Making Changes](#making-changes)
7. [Rollbacks](#rollbacks)
8. [Drift Detection & Self-Healing](#drift-detection--self-healing)
9. [Secrets Management](#secrets-management)
10. [Troubleshooting](#troubleshooting)

---

## What is GitOps?

GitOps is an operational framework that applies DevOps best practices — version control, collaboration, CI/CD — to infrastructure automation. **Git is the single source of truth** for both application code and infrastructure configuration.

The key difference from traditional CD:
- **Traditional CD**: CI pipeline pushes changes directly to the cluster (`kubectl apply`)
- **GitOps**: CI pipeline updates Git manifests → GitOps agent (ArgoCD/Flux) pulls and reconciles

---

## Core Principles

| Principle | Implementation |
|-----------|---------------|
| **Declarative** | All cluster state defined as YAML in Git (Kustomize + Helm) |
| **Versioned & Immutable** | Every change is a Git commit with full audit trail |
| **Pulled automatically** | ArgoCD/Flux continuously reconciles cluster to Git state |
| **Continuously reconciled** | Self-healing: any manual cluster change is reverted |

---

## Workflow Overview

```
┌─────────────────────────────────────────────────────────┐
│                   Developer Workflow                      │
└─────────────────────────────────────────────────────────┘

  1. Developer writes code
  2. Opens PR to `develop` branch
  3. CI runs: lint → test → security scan → build image
  4. PR review + merge
  5. CI updates image tag in GitOps manifests
  6. ArgoCD detects diff → syncs cluster
  7. Dev environment updated ✅

┌─────────────────────────────────────────────────────────┐
│                  Release to Staging                       │
└─────────────────────────────────────────────────────────┘

  1. Create release branch: `release/v1.5.0`
  2. CI builds release image, tags it `v1.5.0`
  3. CI updates staging overlay image tag
  4. ArgoCD syncs staging namespace
  5. QA validates staging environment
  6. Create PR from release → main

┌─────────────────────────────────────────────────────────┐
│                 Production Deployment                     │
└─────────────────────────────────────────────────────────┘

  1. PR merged to `main` (requires 2 approvals)
  2. CI runs full test suite
  3. CI updates production overlay image tag
  4. ArgoCD detects diff in prod manifests
  5. GitHub Environment approval required (manual gate)
  6. ArgoCD syncs production namespace
  7. Smoke tests validate deployment ✅
```

---

## Branch Strategy

```
main ──────────────────────────────────────────── Production
  │
  ├── develop ──────────────────────────────────── Dev environment
  │     │
  │     ├── feature/TICKET-123-add-auth ──────── Feature work
  │     ├── feature/TICKET-456-new-dashboard
  │     └── bugfix/TICKET-789-fix-login
  │
  ├── release/v1.5.0 ───────────────────────────── Staging
  │     └── (cherry-picks from develop)
  │
  └── hotfix/v1.4.1 ────────────────────────────── Emergency prod fix
```

### Branch Rules

| Branch | Protection | Requires | Deploys to |
|--------|-----------|---------|-----------|
| `main` | Protected | 2 reviews + all checks | Production |
| `develop` | Protected | 1 review + all checks | Dev |
| `release/*` | Protected | 1 review + all checks | Staging |
| `feature/*` | None | — | — |
| `hotfix/*` | None | — | — |

---

## How a Deploy Happens

### Step-by-step (Production example)

```bash
# 1. Developer pushes to main (after PR merge)
git push origin main

# 2. GitHub Actions starts automatically
# ↓ quality → test → build → update-manifests → deploy-prod

# 3. CI builds and tags the Docker image
docker build -t ghcr.io/your-org/backend:sha-a1b2c3d .
docker push ghcr.io/your-org/backend:sha-a1b2c3d

# 4. CI updates the Kustomize overlay
cd apps/backend/overlays/prod
kustomize edit set image ghcr.io/your-org/backend:sha-a1b2c3d
git commit -m "chore(gitops): update backend image to sha-a1b2c3d [prod]"
git push

# 5. ArgoCD detects the diff (every 3 minutes or via webhook)
# ArgoCD compares:
#   desired state (Git) vs actual state (cluster)
# It sees the new image tag → marks app OutOfSync

# 6. ArgoCD syncs (auto or manual approval)
argocd app sync backend-production

# 7. Kubernetes performs rolling update
# New pods start → readiness probes pass → old pods terminate

# 8. ArgoCD marks app Synced + Healthy ✅
```

### Image Tag Strategy

| Environment | Tag Format | Example |
|-------------|-----------|---------|
| dev | `latest` | `backend:latest` |
| staging | `sha-<short>` | `backend:sha-a1b2c3d` |
| production | `sha-<short>` or semver | `backend:sha-a1b2c3d` or `backend:v1.5.0` |

---

## Making Changes

### Application Code Change

```bash
# 1. Create feature branch
git checkout develop
git pull origin develop
git checkout -b feature/TICKET-123-add-auth

# 2. Make changes, commit
git add .
git commit -m "feat(auth): add JWT refresh token support"
git push origin feature/TICKET-123-add-auth

# 3. Open PR → develop
# CI runs automatically

# 4. After merge, dev auto-deploys
```

### Kubernetes Manifest Change (e.g., increase memory limit)

```bash
# 1. Edit the manifest
vim apps/backend/overlays/prod/deployment-patch.yaml

# 2. Validate with kustomize
kustomize build apps/backend/overlays/prod | kubectl apply --dry-run=client -f -

# 3. Commit and push
git add apps/backend/overlays/prod/deployment-patch.yaml
git commit -m "fix(backend): increase memory limit to 1Gi for prod"
git push origin main

# 4. ArgoCD detects and syncs
# No image rebuild needed — manifest-only change
```

### Adding a New Environment Variable

```bash
# Option A: Non-sensitive value → ConfigMap
vim apps/backend/overlays/prod/kustomization.yaml
# Add to configMapGenerator:
#   literals:
#     - MY_NEW_VAR=value

# Option B: Sensitive value → SealedSecret
# Generate the secret locally (never commit plaintext!)
kubectl create secret generic app-secrets \
  --from-literal=MY_API_KEY=supersecret \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > apps/backend/overlays/prod/sealed-secret.yaml

# Commit the sealed (encrypted) secret — safe!
git add apps/backend/overlays/prod/sealed-secret.yaml
git commit -m "feat: add MY_API_KEY sealed secret for prod"
```

---

## Rollbacks

### Option 1: ArgoCD UI (fastest)

```
1. Open ArgoCD UI → backend-production
2. Click "History and Rollback"
3. Select the previous successful revision
4. Click "Rollback"
```

### Option 2: ArgoCD CLI

```bash
# List revision history
argocd app history backend-production

# Roll back to specific revision
argocd app rollback backend-production <revision-id>
```

### Option 3: Git Revert (GitOps-native, auditable)

```bash
# Revert the bad commit
git revert <commit-sha>
git push origin main

# ArgoCD auto-syncs to the reverted state
# Full audit trail preserved
```

### Option 4: Revert image tag directly

```bash
cd apps/backend/overlays/prod
kustomize edit set image ghcr.io/your-org/backend:sha-previousgood
git commit -m "revert: rollback backend to sha-previousgood (INCIDENT-123)"
git push origin main
```

> **Rule of thumb**: Always use Git revert in production for full auditability. Use ArgoCD rollback only for immediate emergency recovery, then immediately follow up with a Git revert.

---

## Drift Detection & Self-Healing

ArgoCD continuously compares desired state (Git) vs actual state (cluster) every **3 minutes**.

### What triggers a sync?

1. A new commit changes manifests in Git → ArgoCD detects → syncs
2. Someone manually runs `kubectl apply` on the cluster → ArgoCD detects drift → **reverts** (self-heal)
3. A pod dies and Kubernetes restarts it → normal, ArgoCD doesn't interfere
4. `argocd app sync <name>` run manually → immediate sync

### Self-heal behavior

```yaml
syncPolicy:
  automated:
    selfHeal: true    # Revert manual cluster changes
    prune: true       # Delete resources removed from Git
```

**Example**: An operator runs `kubectl scale deployment backend --replicas=10` directly on the cluster. Within 3 minutes, ArgoCD detects the replica count differs from Git (which says 3) and scales it back to 3.

> **Note**: The HPA (`HorizontalPodAutoscaler`) is excluded from this via `ignoreDifferences` — ArgoCD won't fight with the HPA over replica counts.

---

## Secrets Management

We use **Sealed Secrets** to store encrypted secrets in Git safely.

### Creating a sealed secret

```bash
# 1. Install kubeseal CLI
brew install kubeseal  # macOS

# 2. Get the cluster's public key
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system > /tmp/sealed-secrets.pem

# 3. Create plaintext secret (temporary — never commit this)
kubectl create secret generic my-secret \
  --from-literal=API_KEY=supersecretvalue \
  --dry-run=client -o yaml > /tmp/my-secret.yaml

# 4. Seal it
kubeseal --cert /tmp/sealed-secrets.pem \
  --format yaml < /tmp/my-secret.yaml > sealed-my-secret.yaml

# 5. Commit the sealed secret (safe)
git add sealed-my-secret.yaml
git commit -m "feat: add my-secret sealed secret"

# 6. Clean up plaintext
rm /tmp/my-secret.yaml
```

### Rotating a secret

```bash
# 1. Create new secret value
kubectl create secret generic my-secret \
  --from-literal=API_KEY=newvalue \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > sealed-my-secret.yaml

# 2. Commit + push → ArgoCD applies → secret rotated
```

---

## Troubleshooting

### ArgoCD app stuck in "Progressing"

```bash
# Check app status
argocd app get backend-production

# Check events
kubectl describe application backend-production -n argocd

# Check pod events
kubectl get events -n production --sort-by='.lastTimestamp'

# Check pod logs
kubectl logs -n production -l app=backend --tail=100
```

### ArgoCD app shows "OutOfSync" but sync fails

```bash
# Force refresh (re-fetch from Git)
argocd app get backend-production --refresh

# Check what's different
argocd app diff backend-production

# Hard refresh (re-render manifests)
argocd app terminate-op backend-production
argocd app sync backend-production --force
```

### Image pull errors

```bash
# Check if secret exists
kubectl get secret ghcr-pull-secret -n production

# Describe pod for events
kubectl describe pod <pod-name> -n production

# Verify image exists in registry
docker manifest inspect ghcr.io/your-org/backend:<tag>
```

### Kustomize build fails locally

```bash
# Build with verbose output
kustomize build apps/backend/overlays/prod --enable-alpha-plugins 2>&1

# Validate against cluster
kustomize build apps/backend/overlays/prod | \
  kubectl apply --dry-run=server -f -
```

### Check ArgoCD sync logs

```bash
# View ArgoCD application controller logs
kubectl logs -n argocd \
  -l app.kubernetes.io/name=argocd-application-controller \
  --tail=200

# View repo server logs (manifest rendering)
kubectl logs -n argocd \
  -l app.kubernetes.io/name=argocd-repo-server \
  --tail=200
```

---

## Quick Reference

```bash
# List all apps
argocd app list

# Get app details
argocd app get <app-name>

# Sync an app
argocd app sync <app-name>

# Watch sync status
argocd app wait <app-name> --health

# View diff
argocd app diff <app-name>

# Force sync with prune
argocd app sync <app-name> --prune --force

# Rollback
argocd app rollback <app-name> <revision>

# Port-forward ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
