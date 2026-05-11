#!/usr/bin/env bash
#
# 01-install-rook.sh
# Cài Rook-Ceph operator + CephCluster + StorageClass
# Chạy trên MASTER node (nơi có kubectl)
#
# Env vars:
#   ROOK_VERSION    - Phiên bản Rook (default: v1.14.9)
#   WAIT_TIMEOUT    - Giây timeout đợi operator (default: 300)
#   SKIP_PREPARE    - Skip bước prepare node nếu đã làm rồi (default: 0)
#   WORKER_NODES    - Danh sách IP worker cách nhau dấu phẩy (vd: "10.0.0.2,10.0.0.3")
#                    Để trống nếu đã chạy 00-prepare-nodes.sh thủ công
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Cần root: sudo $0"; exit 1; }

ROOK_VERSION="${ROOK_VERSION:-v1.14.9}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
SKIP_PREPARE="${SKIP_PREPARE:-0}"
WORKER_NODES="${WORKER_NODES:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"
ROOK_BASE="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"

log "================================================="
log " Rook-Ceph Install"
log "  ROOK_VERSION  = ${ROOK_VERSION}"
log "  WAIT_TIMEOUT  = ${WAIT_TIMEOUT}s"
log "  MANIFEST_DIR  = ${MANIFEST_DIR}"
log "================================================="
echo

# ============================================================
# Pre-flight
# ============================================================
log "==> Pre-flight check"

if ! kubectl cluster-info &>/dev/null; then
  error "Không kết nối được cluster. Kiểm tra ~/.kube/config"
  exit 1
fi

READY=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l)
TOTAL=$(kubectl get nodes --no-headers | wc -l)
log "Nodes: ${READY}/${TOTAL} Ready"
kubectl get nodes -o wide

if [[ "${READY}" -lt 2 ]]; then
  error "Cần ít nhất 2 node Ready để chạy Ceph."
  exit 1
fi

# ============================================================
# BƯỚC 1: Prepare worker nodes (tạo loop device OSD)
# ============================================================
if [[ "${SKIP_PREPARE}" != "1" && -n "${WORKER_NODES}" ]]; then
  log "==> [1/5] Prepare worker nodes qua SSH"

  IFS=',' read -ra NODES <<< "${WORKER_NODES}"
  for NODE_IP in "${NODES[@]}"; do
    NODE_IP="${NODE_IP// /}"
    log "Preparing node ${NODE_IP}..."
    scp -o StrictHostKeyChecking=no \
      "${SCRIPT_DIR}/00-prepare-nodes.sh" \
      root@"${NODE_IP}":/tmp/00-prepare-nodes.sh
    ssh -o StrictHostKeyChecking=no root@"${NODE_IP}" \
      "chmod +x /tmp/00-prepare-nodes.sh && sudo /tmp/00-prepare-nodes.sh"
    log "  ✅ ${NODE_IP} prepared"
  done

elif [[ "${SKIP_PREPARE}" == "1" ]]; then
  log "==> [1/5] Skip prepare nodes (SKIP_PREPARE=1)"
else
  warn "WORKER_NODES không được set."
  warn "Nếu chưa chạy 00-prepare-nodes.sh trên worker nodes, hãy làm thủ công trước!"
  read -rp "Tiếp tục không? (yes/no): " confirm
  [[ "${confirm}" != "yes" ]] && exit 1
fi

# ============================================================
# BƯỚC 2: Cài Rook operator
# ============================================================
log "==> [2/5] Cài Rook Operator (${ROOK_VERSION})"

# CRDs
log "Apply CRDs..."
kubectl apply --server-side -f "${ROOK_BASE}/crds.yaml"

# Common
log "Apply common resources..."
kubectl apply -f "${ROOK_BASE}/common.yaml"

# Operator
log "Apply operator..."
kubectl apply -f "${ROOK_BASE}/operator.yaml"

# Đợi operator ready
log "Đợi Rook operator ready (${WAIT_TIMEOUT}s)..."
kubectl -n rook-ceph rollout status deployment/rook-ceph-operator \
  --timeout="${WAIT_TIMEOUT}s"
log "Operator ready ✅"

# ============================================================
# BƯỚC 3: Deploy CephCluster
# ============================================================
log "==> [3/5] Deploy CephCluster"

# Dùng manifest local (đã tuỳ chỉnh cho loop device)
kubectl apply -f "${MANIFEST_DIR}/cluster.yaml"

log "Đợi CephCluster khởi tạo — đây có thể mất 5-10 phút..."
log "(Theo dõi: kubectl -n rook-ceph get pods -w)"

# Đợi MON pods trước
log "Đợi MON pods..."
kubectl -n rook-ceph wait pod \
  -l app=rook-ceph-mon \
  --for=condition=Ready \
  --timeout=600s 2>/dev/null || warn "MON timeout, tiếp tục..."

# Đợi MGR
log "Đợi MGR pod..."
kubectl -n rook-ceph wait pod \
  -l app=rook-ceph-mgr \
  --for=condition=Ready \
  --timeout=300s 2>/dev/null || warn "MGR timeout, tiếp tục..."

# Đợi OSD
log "Đợi OSD pods (có thể lâu nhất)..."
ELAPSED=0
until kubectl -n rook-ceph get pods -l app=rook-ceph-osd 2>/dev/null \
    | grep -q "Running"; do
  sleep 10
  ELAPSED=$((ELAPSED+10))
  echo -n "."
  if [[ ${ELAPSED} -ge 600 ]]; then
    warn "OSD timeout sau 600s. Check: kubectl -n rook-ceph get pods"
    break
  fi
done
echo ""

kubectl -n rook-ceph get pods -o wide

# ============================================================
# BƯỚC 4: Apply StorageClass
# ============================================================
log "==> [4/5] Tạo StorageClass (RBD + CephFS)"

kubectl apply -f "${MANIFEST_DIR}/storageclass.yaml"

log "Đợi CephBlockPool và CephFilesystem (60s)..."
sleep 60

# Verify StorageClass
log "StorageClasses:"
kubectl get sc

# ============================================================
# BƯỚC 5: Verify
# ============================================================
log "==> [5/5] Verify cluster"

# Lấy cluster health qua toolbox
log "Deploy Rook toolbox để check ceph status..."
kubectl apply -f "${ROOK_BASE}/toolbox.yaml"
kubectl -n rook-ceph rollout status deployment/rook-ceph-tools \
  --timeout=120s 2>/dev/null || true

sleep 10

log "Ceph cluster status:"
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status 2>/dev/null \
  || warn "Toolbox chưa ready, check sau: kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status"

# ============================================================
# Summary
# ============================================================
DASHBOARD_PASS=$(kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<chưa có>")

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
  | awk '{print $1}')

log ""
log "🎉 Rook-Ceph đã cài xong!"
log ""
log "StorageClass:"
kubectl get sc
log ""
log "Dashboard:"
log "  kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 8443:8443"
log "  Truy cập: https://localhost:8443"
log "  User: admin / Pass: ${DASHBOARD_PASS}"
log ""
log "Lệnh hữu ích:"
log "  Trạng thái:  sudo ./scripts/status.sh"
log "  Ceph CLI:    kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status"
log "  Teardown:    sudo ./scripts/teardown.sh"
