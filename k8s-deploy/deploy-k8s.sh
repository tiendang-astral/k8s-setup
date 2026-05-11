#!/usr/bin/env bash
# =============================================================================
# DocFlow Platform — Kubernetes Deploy
# =============================================================================
# Usage:
#   ./scripts/deploy-k8s.sh                     # full deploy
#   ./scripts/deploy-k8s.sh --skip-seed         # deploy without seeding
#   DOCPROCESS_REPLICAS=5 ./scripts/deploy-k8s.sh
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
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse flags
SKIP_SEED=false
for arg in "$@"; do
  if [[ "$arg" == "--skip-seed" ]]; then SKIP_SEED=true; fi
done

# =============================================================================
# STEP 1 – Pre-flight check
# =============================================================================
echo -e "\n${BOLD}=== Step 1: Pre-flight check ===${NC}\n"

if ! command -v kubectl &>/dev/null; then
  error "kubectl not found. Install it first."
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  error "Cannot connect to cluster. Check your kubeconfig."
  exit 1
fi

success "Cluster is reachable."

# =============================================================================
# STEP 2 – Apply Database layer
# =============================================================================
echo -e "\n${BOLD}=== Step 2: Applying Database layer ===${NC}\n"

kubectl apply -f "${DEPLOY_DIR}/database/"

info "Waiting for Postgres to be ready..."
kubectl rollout status statefulset/postgres --timeout=120s

info "Waiting for Redis to be ready..."
kubectl rollout status statefulset/redis --timeout=120s

success "Database layer ready."

# =============================================================================
# STEP 3 – Apply MinIO
# =============================================================================
echo -e "\n${BOLD}=== Step 3: Applying MinIO ===${NC}\n"

kubectl apply -f "${DEPLOY_DIR}/min-io/01-min-io.config-map.yml"
kubectl apply -f "${DEPLOY_DIR}/min-io/02-min-io.secret.yml"
kubectl apply -f "${DEPLOY_DIR}/min-io/04-min-io.statefulset.yml"

info "Waiting for MinIO to be ready..."
kubectl rollout status statefulset/minio --timeout=120s

info "Running MinIO init Job (bucket + CORS)..."
kubectl apply -f "${DEPLOY_DIR}/min-io/03-init.job.yml"
kubectl wait --for=condition=complete job/minio-init --timeout=300s 2>/dev/null || {
  warn "MinIO init job did not complete in time. Check with: kubectl logs job/minio-init"
}

success "MinIO stack ready."

# =============================================================================
# STEP 4 – Apply Application
# =============================================================================
echo -e "\n${BOLD}=== Step 4: Applying Application ===${NC}\n"

DOCPROCESS_REPLICAS=${DOCPROCESS_REPLICAS:-3}

kubectl apply -f "${DEPLOY_DIR}/app/01-app.config-map.yml"
kubectl apply -f "${DEPLOY_DIR}/app/02-app.secret.yml"
kubectl apply -f "${DEPLOY_DIR}/app/03-app.pvc.yml"

kubectl apply -f "${DEPLOY_DIR}/app/04-docaiplatform-platform-worker.deployment.yml"

kubectl apply -f "${DEPLOY_DIR}/app/05-docprocess-worker.deployment.yml"
kubectl scale deployment/docprocess-worker --replicas="${DOCPROCESS_REPLICAS}"
info "Scaled docprocess-worker to ${DOCPROCESS_REPLICAS} replica(s)."

kubectl apply -f "${DEPLOY_DIR}/app/06-docaiplatform-backend.deployment.yml"

kubectl apply -f "${DEPLOY_DIR}/app/07-docaiplatform-frontend.deployment.yml"

info "Waiting for all application deployments..."
kubectl rollout status deployment/docaiplatform-backend --timeout=180s
kubectl rollout status deployment/docaiplatform-frontend --timeout=180s
kubectl rollout status deployment/docaiplatform-platform-worker --timeout=180s
kubectl rollout status deployment/docprocess-worker --timeout=180s

success "Application stack ready."

# =============================================================================
# STEP 5 – Apply Monitoring
# =============================================================================
echo -e "\n${BOLD}=== Step 5: Applying Monitoring ===${NC}\n"

kubectl apply -f "${DEPLOY_DIR}/monitoring/"

info "Waiting for Prometheus to be ready..."
kubectl rollout status deployment/prometheus --timeout=120s

info "Waiting for Grafana to be ready..."
kubectl rollout status deployment/grafana --timeout=120s

success "Monitoring stack ready."

# =============================================================================
# STEP 6 – Post-deploy seed (optional)
# =============================================================================
if [ "$SKIP_SEED" = false ]; then
  echo -e "\n${BOLD}=== Step 6: Running seed ===${NC}\n"

  BACKEND_POD=$(kubectl get pods -l app=docaiplatform-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -n "$BACKEND_POD" ]; then
    info "Creating demo users..."
    kubectl exec "$BACKEND_POD" -- python backend/scripts/create_demo_users.py \
      && success "Demo users created." \
      || warn "create_demo_users.py exited with errors (may already exist)."
  else
    warn "Backend pod not found. Skipping seed."
  fi
else
  warn "--skip-seed flag detected. Skipping seed."
fi

# =============================================================================
# Summary
# =============================================================================
echo -e "\n${BOLD}${GREEN}=== Deploy complete ===${NC}\n"

kubectl get pods

echo ""
info "Access points (requires tunnel or port-forward):"
echo "  Frontend       : http://localhost:30000"
echo "  Backend API    : http://localhost:30001/health"
echo "  Grafana        : http://localhost:30002 (admin / <GRAFANA_ADMIN_PASSWORD>)"
echo "  MinIO API      : http://localhost:30003"
echo "  MinIO Console  : http://localhost:30004"
echo ""
info "To expose services, run in a separate terminal:"
echo "  bash scripts/port-forward-k8s.sh"
echo ""
info "Useful commands:"
echo "  Logs (backend) : kubectl logs -l app=docaiplatform-backend -f"
echo "  Teardown       : bash scripts/down-k8s.sh"
echo "  Status         : kubectl get pods"
