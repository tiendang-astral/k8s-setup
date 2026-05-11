#!/usr/bin/env bash
# =============================================================================
# DocFlow Platform — Kubernetes Port-Forward (Minikube)
# =============================================================================
# Run this in a separate terminal after deploy-k8s.sh to expose services.
#   ./scripts/port-forward-k8s.sh
#
# Or use `minikube tunnel` instead (does the same thing at cluster level).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

cleanup() {
  echo ""
  info "Shutting down port-forwards..."
  kill $(jobs -p) 2>/dev/null || true
  wait $(jobs -p) 2>/dev/null || true
  success "All port-forwards stopped."
}
trap cleanup EXIT INT TERM

echo -e "\n${BOLD}Starting port-forwards for DocFlow Platform...${NC}\n"
info "Press Ctrl+C to stop.\n"

# Frontend     :30000 -> 3000
kubectl port-forward svc/docaiplatform-frontend   30000:3000  >/dev/null &
# Backend      :30001 -> 8000
kubectl port-forward svc/docaiplatform-backend    30001:8000  >/dev/null &
# Grafana      :30002 -> 3000
kubectl port-forward svc/grafana                  30002:3000  >/dev/null &
# MinIO API    :30003 -> 9000
kubectl port-forward svc/minio                    30003:9000  >/dev/null &
# MinIO Console:30004 -> 9001
kubectl port-forward svc/minio                    30004:9001  >/dev/null &

sleep 2

echo ""
info "Access points:"
echo "  Frontend       : http://localhost:30000"
echo "  Backend API    : http://localhost:30001/health"
echo "  Grafana        : http://localhost:30002 (admin / <GRAFANA_ADMIN_PASSWORD>)"
echo "  MinIO API      : http://localhost:30003"
echo "  MinIO Console  : http://localhost:30004"
echo ""

wait
