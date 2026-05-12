#!/usr/bin/env bash
#
# 01-install-rook.sh
# Cài Rook-Ceph operator + CephCluster + StorageClass
# Chạy trên MASTER node (nơi có kubectl)
#
# Env vars:
#   ROOK_VERSION    - Phiên bản Rook (default: v1.14.9)
#   WAIT_TIMEOUT    - Giây timeout đợi operator (default: 300)
#   ROOK_IMAGE      - Image operator Rook (default: docker.io/rook/ceph:<ROOK_VERSION>)
#   CEPH_IMAGE      - Image Ceph cho cluster/toolbox (default: quay.io/ceph/ceph:v18.2.4)
#   ROOK_CSI_CEPH_IMAGE         - Image cephcsi
#   ROOK_CSI_REGISTRAR_IMAGE    - Image csi-node-driver-registrar
#   ROOK_CSI_RESIZER_IMAGE      - Image csi-resizer
#   ROOK_CSI_PROVISIONER_IMAGE  - Image csi-provisioner
#   ROOK_CSI_SNAPSHOTTER_IMAGE  - Image csi-snapshotter
#   ROOK_CSI_ATTACHER_IMAGE     - Image csi-attacher
#
# Yêu cầu trước khi chạy:
#   Đã chạy 00-prepare-nodes.sh trên TẤT CẢ worker node
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Cần root: sudo $0"; exit 1; }

ROOK_VERSION="${ROOK_VERSION:-v1.14.9}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"
ROOK_BASE="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"
TMP_DIR="$(mktemp -d)"
ROOK_IMAGE="${ROOK_IMAGE:-docker.io/rook/ceph:${ROOK_VERSION}}"
CEPH_IMAGE="${CEPH_IMAGE:-quay.io/ceph/ceph:v18.2.4}"
ROOK_CSI_CEPH_IMAGE="${ROOK_CSI_CEPH_IMAGE:-quay.io/cephcsi/cephcsi:v3.11.0}"
ROOK_CSI_REGISTRAR_IMAGE="${ROOK_CSI_REGISTRAR_IMAGE:-registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.1}"
ROOK_CSI_RESIZER_IMAGE="${ROOK_CSI_RESIZER_IMAGE:-registry.k8s.io/sig-storage/csi-resizer:v1.10.1}"
ROOK_CSI_PROVISIONER_IMAGE="${ROOK_CSI_PROVISIONER_IMAGE:-registry.k8s.io/sig-storage/csi-provisioner:v4.0.1}"
ROOK_CSI_SNAPSHOTTER_IMAGE="${ROOK_CSI_SNAPSHOTTER_IMAGE:-registry.k8s.io/sig-storage/csi-snapshotter:v7.0.2}"
ROOK_CSI_ATTACHER_IMAGE="${ROOK_CSI_ATTACHER_IMAGE:-registry.k8s.io/sig-storage/csi-attacher:v4.5.1}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log "================================================="
log " Rook-Ceph Install"
log "  ROOK_VERSION  = ${ROOK_VERSION}"
log "  WAIT_TIMEOUT  = ${WAIT_TIMEOUT}s"
log "  MANIFEST_DIR  = ${MANIFEST_DIR}"
log "  ROOK_IMAGE    = ${ROOK_IMAGE}"
log "  CEPH_IMAGE    = ${CEPH_IMAGE}"
log "================================================="
echo

render_operator_manifest() {
  local out="${TMP_DIR}/operator.yaml"
  curl -fsSL "${ROOK_BASE}/operator.yaml" -o "${out}"
  sed -i "s|image: rook/ceph:.*|image: ${ROOK_IMAGE}|" "${out}"
  python3 - "${out}" \
    "${ROOK_CSI_CEPH_IMAGE}" \
    "${ROOK_CSI_REGISTRAR_IMAGE}" \
    "${ROOK_CSI_RESIZER_IMAGE}" \
    "${ROOK_CSI_PROVISIONER_IMAGE}" \
    "${ROOK_CSI_SNAPSHOTTER_IMAGE}" \
    "${ROOK_CSI_ATTACHER_IMAGE}" <<'PYEOF'
import sys

path, csi_ceph, registrar, resizer, provisioner, snapshotter, attacher = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    content = f.read()

anchor = '  ROOK_CSI_ALLOW_UNSUPPORTED_VERSION: "false"\n'
block = (
    anchor +
    f'  ROOK_CSI_CEPH_IMAGE: "{csi_ceph}"\n'
    f'  ROOK_CSI_REGISTRAR_IMAGE: "{registrar}"\n'
    f'  ROOK_CSI_RESIZER_IMAGE: "{resizer}"\n'
    f'  ROOK_CSI_PROVISIONER_IMAGE: "{provisioner}"\n'
    f'  ROOK_CSI_SNAPSHOTTER_IMAGE: "{snapshotter}"\n'
    f'  ROOK_CSI_ATTACHER_IMAGE: "{attacher}"\n'
)

if anchor not in content:
    raise SystemExit("Không tìm thấy anchor ROOK_CSI_ALLOW_UNSUPPORTED_VERSION trong operator.yaml")

content = content.replace(anchor, block, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
  echo "${out}"
}

render_cluster_manifest() {
  local out="${TMP_DIR}/cluster.yaml"
  cp "${MANIFEST_DIR}/cluster.yaml" "${out}"
  sed -i "s|image: .*|image: ${CEPH_IMAGE}|" "${out}"
  echo "${out}"
}

render_toolbox_manifest() {
  local out="${TMP_DIR}/toolbox.yaml"
  curl -fsSL "${ROOK_BASE}/toolbox.yaml" -o "${out}"
  sed -i "s|image: .*|image: ${CEPH_IMAGE}|" "${out}"
  echo "${out}"
}

check_image_pull_failures() {
  local failed
  failed="$(kubectl -n rook-ceph get pods --no-headers 2>/dev/null | awk '$3 ~ /ErrImagePull|ImagePullBackOff|Init:ErrImagePull|Init:ImagePullBackOff/ {print $1; exit}')"
  if [[ -n "${failed}" ]]; then
    error "Pod ${failed} bị lỗi pull image."
    kubectl -n rook-ceph describe pod "${failed}" || true
    exit 1
  fi
}

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
# BƯỚC 1: Cài Rook operator
# ============================================================
log "==> [1/4] Cài Rook Operator (${ROOK_VERSION})"

# CRDs
log "Apply CRDs..."
kubectl apply --server-side -f "${ROOK_BASE}/crds.yaml"

# Common
log "Apply common resources..."
kubectl apply -f "${ROOK_BASE}/common.yaml"

# Operator
log "Apply operator..."
OPERATOR_MANIFEST="$(render_operator_manifest)"
kubectl apply -f "${OPERATOR_MANIFEST}"

# Đợi operator ready
log "Đợi Rook operator ready (${WAIT_TIMEOUT}s)..."
kubectl -n rook-ceph rollout status deployment/rook-ceph-operator \
  --timeout="${WAIT_TIMEOUT}s"
log "Operator ready ✅"

# ============================================================
# BƯỚC 3: Deploy CephCluster
# ============================================================
log "==> [2/4] Deploy CephCluster"

# Dùng manifest local (đã tuỳ chỉnh cho loop device)
CLUSTER_MANIFEST="$(render_cluster_manifest)"
kubectl apply -f "${CLUSTER_MANIFEST}"

log "Đợi CephCluster khởi tạo — đây có thể mất 5-10 phút..."
log "(Theo dõi: kubectl -n rook-ceph get pods -w)"
sleep 10
check_image_pull_failures

# Đợi MON pods trước
log "Đợi MON pods..."
kubectl -n rook-ceph wait pod \
  -l app=rook-ceph-mon \
  --for=condition=Ready \
  --timeout=600s 2>/dev/null || warn "MON timeout, tiếp tục..."
check_image_pull_failures

# Đợi MGR
log "Đợi MGR pod..."
kubectl -n rook-ceph wait pod \
  -l app=rook-ceph-mgr \
  --for=condition=Ready \
  --timeout=300s 2>/dev/null || warn "MGR timeout, tiếp tục..."
check_image_pull_failures

# Đợi OSD
log "Đợi OSD pods (có thể lâu nhất)..."
ELAPSED=0
until kubectl -n rook-ceph get pods -l app=rook-ceph-osd 2>/dev/null \
    | grep -q "Running"; do
  sleep 10
  ELAPSED=$((ELAPSED+10))
  echo -n "."
  check_image_pull_failures
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
log "==> [3/4] Tạo StorageClass (RBD + CephFS)"

kubectl apply -f "${MANIFEST_DIR}/storageclass.yaml"

log "Đợi CephBlockPool và CephFilesystem (60s)..."
sleep 60

# Verify StorageClass
log "StorageClasses:"
kubectl get sc

# ============================================================
# BƯỚC 5: Verify
# ============================================================
log "==> [4/4] Verify cluster"

# Lấy cluster health qua toolbox
log "Deploy Rook toolbox để check ceph status..."
TOOLBOX_MANIFEST="$(render_toolbox_manifest)"
kubectl apply -f "${TOOLBOX_MANIFEST}"
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
