#!/usr/bin/env bash
# ==============================================================
# validate-manifests.sh — Validate all Kustomize overlays
# Usage: ./scripts/validate-manifests.sh [overlay-path]
# ==============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ERRORS=0
VALIDATED=0

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}✅ $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; ((ERRORS++)); }
info() { echo -e "${YELLOW}🔍 $*${NC}"; }

# Find all kustomization.yaml files
OVERLAYS=$(find "$PROJECT_ROOT/apps" "$PROJECT_ROOT/infrastructure" \
  -name "kustomization.yaml" | sort)

info "Validating Kustomize overlays..."
echo ""

for overlay in $OVERLAYS; do
  dir=$(dirname "$overlay")
  rel=$(realpath --relative-to="$PROJECT_ROOT" "$dir")

  echo -n "  $rel ... "

  if output=$(kustomize build "$dir" 2>&1); then
    # Validate the output YAML is parseable
    if echo "$output" | python3 -c "import sys,yaml; list(yaml.safe_load_all(sys.stdin))" 2>/dev/null; then
      echo -e "${GREEN}OK${NC}"
      ((VALIDATED++))
    else
      echo -e "${RED}INVALID YAML${NC}"
      err "$rel produced invalid YAML"
    fi
  else
    echo -e "${RED}BUILD FAILED${NC}"
    echo "$output" | head -20
    err "$rel failed to build"
  fi
done

echo ""
echo "Results: $VALIDATED validated, $ERRORS errors"

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}Validation FAILED${NC}"
  exit 1
else
  log "All overlays validated successfully"
fi
