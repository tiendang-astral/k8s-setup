#!/usr/bin/env bash
#
# teardown.sh — Gỡ hoàn toàn Rook-Ceph khỏi cluster K8s
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Cần root: sudo $0"; exit 1; }

ROOK_VERSION="${ROOK_VERSION:-v1.14.9}"
ROOK_BASE="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"
WORKER_NODES="${WORKER_NODES:-}"

warn "⚠️  Cảnh báo: Xóa TOÀN BỘ Rook-Ceph và data!"
read -rp "Gõ 'yes' để xác nhận: " confirm
[[ "${confirm}" != "yes" ]] && { log "Đã hủy."; exit 0; }

log "==> [1/5] Xóa StorageClass và pool"
kubectl delete -f manifests/storageclass.yaml --ignore-not-found
kubectl delete cephblockpool --all -n rook-ceph --ignore-not-found
kubectl delete cephfilesystem --all -n rook-ceph --ignore-not-found

log "==> [2/5] Xóa CephCluster"
# Phải patch cleanup policy trước
kubectl -n rook-ceph patch cephcluster rook-ceph \
  --type merge -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}' \
  2>/dev/null || true
kubectl delete -f manifests/cluster.yaml --ignore-not-found
sleep 10

log "==> [3/5] Xóa Rook operator và toolbox"
kubectl delete -f "${ROOK_BASE}/toolbox.yaml" --ignore-not-found
kubectl delete -f "${ROOK_BASE}/operator.yaml" --ignore-not-found
kubectl delete -f "${ROOK_BASE}/common.yaml" --ignore-not-found
kubectl delete -f "${ROOK_BASE}/crds.yaml" --ignore-not-found 2>/dev/null || true

log "==> [4/5] Xóa namespace rook-ceph"
kubectl delete namespace rook-ceph --ignore-not-found

log "==> [5/5] Dọn dẹp data trên các node"
NODES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null || echo "")

CLEANUP_CMD='
  rm -rf /var/lib/rook
  losetup -d /dev/loop200 2>/dev/null || true
  wipefs -af /dev/loop200 2>/dev/null || true
  systemctl disable rook-osd-loop 2>/dev/null || true
  rm -f /etc/systemd/system/rook-osd-loop.service
  systemctl daemon-reload
'

for NODE_IP in ${NODES}; do
  log "Cleanup node ${NODE_IP}..."
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    root@"${NODE_IP}" "${CLEANUP_CMD}" 2>/dev/null \
    || warn "Không SSH được ${NODE_IP}, dọn thủ công: ${CLEANUP_CMD}"
done

log ""
log "✅ Rook-Ceph đã được gỡ hoàn toàn."
log "Chạy lại: sudo ./setup-rook.sh"
