# Operations Runbook

## Incident Response — Quick Reference

### Severity Levels

| Level | Definition | Response Time | Examples |
|-------|-----------|---------------|---------|
| P1 – Critical | Production down / data loss | 15 min | All pods crashing, DB unavailable |
| P2 – High | Degraded production service | 30 min | High error rate, latency spike |
| P3 – Medium | Partial degradation | 2 hours | Feature broken, non-critical service |
| P4 – Low | Minor issue | Next business day | UI glitch, log noise |

---

## Runbook 1: Pod CrashLooping

**Alert**: `PodCrashLooping`

```bash
# 1. Identify crashing pod
kubectl get pods -n production | grep -v Running

# 2. Check restart count and events
kubectl describe pod <pod-name> -n production

# 3. Check current logs
kubectl logs <pod-name> -n production --tail=100

# 4. Check previous crash logs
kubectl logs <pod-name> -n production --previous --tail=100

# 5. Check resource limits (OOMKill?)
kubectl get events -n production \
  --field-selector reason=OOMKilling \
  --sort-by='.lastTimestamp'

# If OOMKill: increase memory limit in deployment-patch.yaml and push
# If config error: check configmap/secret values
# If startup failure: check initContainers

# 6. Temporary relief: scale down bad pod
kubectl rollout undo deployment/backend -n production

# 7. Long-term fix: update manifests in Git → push → let ArgoCD sync
```

---

## Runbook 2: High Error Rate (5xx)

**Alert**: `HighErrorRate`

```bash
# 1. Check error rate dashboard in Grafana
# URL: https://grafana.example.com/d/gitops-overview

# 2. Identify which endpoints are failing
kubectl logs -n production -l app=backend --tail=500 | grep "ERROR\|5[0-9][0-9]"

# 3. Check if DB is healthy
kubectl exec -n production deploy/backend -- \
  sh -c "pg_isready -h postgres-service -p 5432"

# 4. Check downstream dependencies
kubectl exec -n production deploy/backend -- \
  sh -c "curl -s http://internal-service/health"

# 5. Check pod resource usage
kubectl top pods -n production

# 6. If recent deployment is the cause — rollback
argocd app rollback backend-production <previous-revision>
# Then immediately follow with git revert!

# 7. Notify stakeholders via Slack #incidents
```

---

## Runbook 3: ArgoCD Out of Sync

**Alert**: `ArgoCDSyncFailed`

```bash
# 1. Get app status
argocd app get <app-name>

# 2. Check what's different
argocd app diff <app-name>

# 3. Check for sync errors
argocd app get <app-name> -o json | jq '.status.conditions'

# 4. Common causes:
#    - CRD not installed yet (dependency ordering issue)
#    - Invalid YAML in manifests (check kustomize build locally)
#    - RBAC permissions insufficient
#    - Resource quota exceeded

# 5. Manual sync with debug
argocd app sync <app-name> --debug

# 6. If resource quota:
kubectl describe resourcequota -n <namespace>
# Then increase quota in infrastructure/namespaces/namespaces.yaml

# 7. If CRD missing:
kubectl apply -f https://raw.githubusercontent.com/... # install CRD
# Then re-sync
```

---

## Runbook 4: Database Connection Issues

**Alert**: `PostgreSQLDown`

```bash
# 1. Check postgres pod status
kubectl get pods -n production -l app=postgres

# 2. Check postgres logs
kubectl logs -n production -l app=postgres --tail=200

# 3. Check postgres events
kubectl describe statefulset postgres -n production

# 4. Test connectivity from backend
kubectl exec -n production deploy/backend -- \
  sh -c "nc -zv postgres-service 5432 && echo 'DB reachable'"

# 5. Check PVC health
kubectl get pvc -n production
kubectl describe pvc postgres-data-postgres-0 -n production

# 6. If pod stuck in Pending (PVC issue):
kubectl get events -n production | grep postgres

# 7. Emergency: connect to postgres directly
kubectl exec -it -n production statefulset/postgres -- \
  psql -U appuser -d appdb

# 8. Check replication lag (if replica):
#   SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

---

## Runbook 5: Node Pressure / OOM

```bash
# 1. Check node resource usage
kubectl top nodes

# 2. Check which pods are consuming most resources
kubectl top pods -n production --sort-by=memory

# 3. Check node conditions
kubectl describe node <node-name> | grep -A10 Conditions

# 4. Evict low-priority pods if needed
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 5. Cordon node to prevent new scheduling
kubectl cordon <node-name>

# 6. Add node to cluster (cloud provider specific)
# AWS EKS: update node group desired capacity
# GKE: gcloud container clusters resize ...

# 7. Uncordon after recovery
kubectl uncordon <node-name>
```

---

## Maintenance Procedures

### Planned Upgrade: Kubernetes Version

```bash
# 1. Check current version
kubectl version

# 2. Review release notes for breaking changes
# https://kubernetes.io/releases/

# 3. Test in dev cluster first
# Update kind config version → recreate dev cluster → validate all apps

# 4. Backup etcd (managed clusters do this automatically)

# 5. Upgrade control plane (provider-specific)
# EKS: eksctl upgrade cluster --name prod --version 1.30
# GKE: gcloud container clusters upgrade prod --master --cluster-version 1.30

# 6. Upgrade node groups (rolling)
# Update nodes one by one to avoid downtime

# 7. Validate cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running
argocd app list
```

### Rotating Sealed Secrets

```bash
# When cluster private key changes (e.g., DR restore), all SealedSecrets
# must be re-encrypted with the new key.

# 1. Get new cluster cert
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system > /tmp/new-cert.pem

# 2. Re-seal all secrets (script):
find . -name "sealed-secret.yaml" | while read f; do
  echo "Re-sealing: $f"
  # Extract original values (requires access to cluster)
  kubectl get secret $(yq .metadata.name $f) -n $(yq .metadata.namespace $f) \
    -o yaml | \
    kubeseal --cert /tmp/new-cert.pem --format yaml > $f
done

# 3. Commit and push all re-sealed secrets
git add -A
git commit -m "chore: re-seal all secrets after key rotation"
git push
```

---

## Useful kubectl Aliases

Add to your `~/.bashrc` or `~/.zshrc`:

```bash
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias kd='kubectl describe'
alias ke='kubectl exec -it'
alias kpf='kubectl port-forward'
alias kg='kubectl get'
alias ktop='kubectl top pods'

# Switch namespace
alias kns='kubectl config set-context --current --namespace'

# ArgoCD shortcuts
alias aapp='argocd app'
alias async='argocd app sync'
alias aget='argocd app get'
alias adiff='argocd app diff'
```
