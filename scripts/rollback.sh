#!/usr/bin/env bash
# ==============================================================
# rollback.sh — GitOps-native rollback via git revert
# Usage: ./scripts/rollback.sh --app backend --env prod [--revision <sha>]
# ==============================================================

set -euo pipefail

APP=""
ENV=""
REVISION=""
DRY_RUN=false

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%T')] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%T')] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +'%T')] ❌ $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}[$(date +'%T')] ℹ️  $*${NC}"; }

usage() {
  cat <<EOF
Usage: $0 --app APP --env ENV [--revision SHA] [--dry-run]

Options:
  --app       App name (frontend|backend|database)
  --env       Environment (dev|staging|prod)
  --revision  Git SHA to revert to (default: one commit before HEAD)
  --dry-run   Show what would happen without making changes

Examples:
  $0 --app backend --env prod
  $0 --app backend --env prod --revision abc1234
  $0 --app backend --env prod --dry-run
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --app) APP="$2"; shift 2 ;;
    --env) ENV="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) usage ;;
  esac
done

[[ -z "$APP" || -z "$ENV" ]] && usage

OVERLAY_PATH="apps/$APP/overlays/$ENV"
ARGOCD_APP="$APP-$ENV"

info "Rollback requested:"
info "  App: $APP"
info "  Env: $ENV"
info "  Overlay: $OVERLAY_PATH"
[[ -n "$REVISION" ]] && info "  Target: $REVISION"
[[ "$DRY_RUN" == "true" ]] && warn "DRY RUN MODE — no changes will be made"
echo ""

# Get current image tag
CURRENT_TAG=$(cd "$OVERLAY_PATH" && kustomize cfg grep "newTag" kustomization.yaml 2>/dev/null | awk '{print $2}' || echo "unknown")
info "Current image tag: $CURRENT_TAG"

# Get git history for this overlay
info "Recent changes to $OVERLAY_PATH:"
git log --oneline -10 -- "$OVERLAY_PATH/"
echo ""

# Determine revision to revert to
if [[ -z "$REVISION" ]]; then
  # Default: one commit before the latest change to this overlay
  REVISION=$(git log --oneline -2 -- "$OVERLAY_PATH/" | tail -1 | awk '{print $1}')
  info "Auto-selected revision: $REVISION"
fi

# Show what will change
info "Changes between HEAD and $REVISION for $OVERLAY_PATH:"
git diff "$REVISION" HEAD -- "$OVERLAY_PATH/"

if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY RUN complete. Run without --dry-run to apply."
  exit 0
fi

# Confirm
echo ""
warn "This will create a Git revert commit and push to main."
read -rp "Confirm rollback? (type 'yes'): " confirm
[[ "$confirm" != "yes" ]] && err "Aborted."

# Create a revert commit (GitOps-native approach — not git revert which replays)
info "Checking out overlay files from $REVISION..."
git checkout "$REVISION" -- "$OVERLAY_PATH/"

INCIDENT_ID="ROLLBACK-$(date +%Y%m%d-%H%M%S)"
git add "$OVERLAY_PATH/"
git commit -m "revert($APP): rollback $ENV to $REVISION [$INCIDENT_ID]

Rolled back $APP in $ENV from $CURRENT_TAG to revision $REVISION.
Triggered by: $(git config user.name) <$(git config user.email)>
Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

This is a GitOps rollback. See ArgoCD for sync status.
[skip ci]"

git push origin main

log "Rollback commit pushed! ArgoCD will sync within 3 minutes."
info "To watch: argocd app wait $ARGOCD_APP --health"
info "To force immediate sync: argocd app sync $ARGOCD_APP"
