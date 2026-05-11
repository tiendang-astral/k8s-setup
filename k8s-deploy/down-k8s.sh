#!/usr/bin/env bash
# =============================================================================
# DocFlow Platform — Kubernetes Teardown
# =============================================================================
# Usage:
#   ./scripts/down-k8s.sh             # delete all resources
#   ./scripts/down-k8s.sh --keep-pvc  # delete everything except PVCs
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

DEPLOY_DIR="deployment"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# Parse flags
KEEP_PVC=false
for arg in "$@"; do
  if [[ "$arg" == "--keep-pvc" ]]; then KEEP_PVC=true; fi
done

echo -e "\n${BOLD}=== DocFlow Platform — Kubernetes Teardown ===${NC}\n"

if [ "$KEEP_PVC" = true ]; then
  warn "Keeping PVCs — data will be preserved."
  info "Deleting application..."
  kubectl delete -f "${DEPLOY_DIR}/app/" --ignore-not-found

  info "Deleting monitoring..."
  kubectl delete -f "${DEPLOY_DIR}/monitoring/" --ignore-not-found

  info "Deleting MinIO..."
  kubectl delete -f "${DEPLOY_DIR}/min-io/" --ignore-not-found

  info "Deleting database..."
  kubectl delete -f "${DEPLOY_DIR}/database/" --ignore-not-found
else
  info "Deleting application..."
  kubectl delete -f "${DEPLOY_DIR}/app/" --ignore-not-found

  info "Deleting monitoring..."
  kubectl delete -f "${DEPLOY_DIR}/monitoring/" --ignore-not-found

  info "Deleting MinIO..."
  kubectl delete -f "${DEPLOY_DIR}/min-io/" --ignore-not-found

  info "Deleting database..."
  kubectl delete -f "${DEPLOY_DIR}/database/" --ignore-not-found
fi

success "Teardown complete."
echo ""
info "Remaining in namespace:"
kubectl get all 2>/dev/null || echo "  (none)"
