#!/usr/bin/env bash
#
# setup-rook.sh — All-in-one: Cài Rook-Ceph vào K8s cluster hiện tại
#
# Cách dùng (chạy trên master):
#   sudo WORKER_NODES="10.0.0.2,10.0.0.3" ./setup-rook.sh
#
# Nếu đã chạy 00-prepare-nodes.sh thủ công trên từng worker:
#   sudo SKIP_PREPARE=1 ./setup-rook.sh
#
# Env vars:
#   WORKER_NODES   - IP các worker cách nhau dấu phẩy (bắt buộc nếu SKIP_PREPARE=0)
#   ROOK_VERSION   - Phiên bản Rook (default: v1.14.9)
#   SKIP_PREPARE   - Bỏ qua bước prepare node (default: 0)
#   ROOK_IMAGE, CEPH_IMAGE, ROOK_CSI_* - Override image/registry khi cần
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[ROOK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Cần root: sudo $0"; exit 1; }

WORKER_NODES="${WORKER_NODES:-}"
SKIP_PREPARE="${SKIP_PREPARE:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "================================================="
log " Rook-Ceph Setup"
log "================================================="
log "  WORKER_NODES  = ${WORKER_NODES:-<chạy thủ công>}"
log "  SKIP_PREPARE  = ${SKIP_PREPARE}"
log "  ROOK_VERSION  = ${ROOK_VERSION:-v1.14.9}"
log "================================================="
echo

if [[ "${SKIP_PREPARE}" != "1" && -z "${WORKER_NODES}" ]]; then
  error "Cần set WORKER_NODES hoặc SKIP_PREPARE=1"
  error "Ví dụ: sudo WORKER_NODES='10.0.0.2,10.0.0.3' ./setup-rook.sh"
  exit 1
fi

log "==> Bước 1/2: Cài Rook Operator + CephCluster + StorageClass"
WORKER_NODES="${WORKER_NODES}" \
SKIP_PREPARE="${SKIP_PREPARE}" \
ROOK_VERSION="${ROOK_VERSION:-v1.14.9}" \
ROOK_IMAGE="${ROOK_IMAGE:-}" \
CEPH_IMAGE="${CEPH_IMAGE:-}" \
ROOK_CSI_CEPH_IMAGE="${ROOK_CSI_CEPH_IMAGE:-}" \
ROOK_CSI_REGISTRAR_IMAGE="${ROOK_CSI_REGISTRAR_IMAGE:-}" \
ROOK_CSI_RESIZER_IMAGE="${ROOK_CSI_RESIZER_IMAGE:-}" \
ROOK_CSI_PROVISIONER_IMAGE="${ROOK_CSI_PROVISIONER_IMAGE:-}" \
ROOK_CSI_SNAPSHOTTER_IMAGE="${ROOK_CSI_SNAPSHOTTER_IMAGE:-}" \
ROOK_CSI_ATTACHER_IMAGE="${ROOK_CSI_ATTACHER_IMAGE:-}" \
  bash "${SCRIPT_DIR}/scripts/01-install-rook.sh"

log "==> Bước 2/2: Test PVC"
bash "${SCRIPT_DIR}/scripts/test-pvc.sh"

log ""
log "🎉 Rook-Ceph đã sẵn sàng!"
log ""
log "StorageClass mặc định: rook-ceph-block (ReadWriteOnce)"
log "StorageClass CephFS:   rook-cephfs     (ReadWriteMany)"
log ""
log "Lệnh hữu ích:"
log "  Trạng thái:    sudo ./scripts/status.sh"
log "  Ceph CLI:      kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status"
log "  Dashboard:     kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 8443:8443"
log "  Test PVC:      sudo ./scripts/test-pvc.sh"
log "  Teardown:      sudo ./scripts/teardown.sh"
