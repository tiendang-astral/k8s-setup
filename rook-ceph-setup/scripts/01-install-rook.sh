#!/usr/bin/env bash
#
# 01-install-rook.sh
# Cai Rook-Ceph operator + CephCluster + StorageClass
# Chay tren MASTER node (noi co kubectl)
#
# Env vars:
#   ROOK_VERSION               - Phien ban Rook (default: v1.14.9)
#   WAIT_TIMEOUT               - Timeout mac dinh cho rollout/wait (default: 300)
#   ROOK_NAMESPACE             - Namespace Rook-Ceph (default: rook-ceph)
#   ROOK_IMAGE                 - Image operator Rook (default: docker.io/rook/ceph:<ROOK_VERSION>)
#   CEPH_IMAGE                 - Image Ceph cho cluster/toolbox (default: quay.io/ceph/ceph:v18.2.4)
#   ROOK_CSI_CEPH_IMAGE        - Image cephcsi
#   ROOK_CSI_REGISTRAR_IMAGE   - Image csi-node-driver-registrar
#   ROOK_CSI_RESIZER_IMAGE     - Image csi-resizer
#   ROOK_CSI_PROVISIONER_IMAGE - Image csi-provisioner
#   ROOK_CSI_SNAPSHOTTER_IMAGE - Image csi-snapshotter
#   ROOK_CSI_ATTACHER_IMAGE    - Image csi-attacher
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Can root: sudo $0"; exit 1; }

ROOK_VERSION="${ROOK_VERSION:-v1.14.9}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
ROOK_NAMESPACE="${ROOK_NAMESPACE:-rook-ceph}"
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { error "Thieu command: $1"; exit 1; }
}

print_header() {
  log "================================================="
  log " Rook-Ceph Install"
  log "  ROOK_VERSION  = ${ROOK_VERSION}"
  log "  WAIT_TIMEOUT  = ${WAIT_TIMEOUT}s"
  log "  NAMESPACE     = ${ROOK_NAMESPACE}"
  log "  MANIFEST_DIR  = ${MANIFEST_DIR}"
  log "  ROOK_IMAGE    = ${ROOK_IMAGE}"
  log "  CEPH_IMAGE    = ${CEPH_IMAGE}"
  log "================================================="
  echo
}

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
if anchor not in content:
    raise SystemExit("Khong tim thay anchor ROOK_CSI_ALLOW_UNSUPPORTED_VERSION trong operator.yaml")

inject = (
    anchor +
    f'  ROOK_CSI_CEPH_IMAGE: "{csi_ceph}"\n'
    f'  ROOK_CSI_REGISTRAR_IMAGE: "{registrar}"\n'
    f'  ROOK_CSI_RESIZER_IMAGE: "{resizer}"\n'
    f'  ROOK_CSI_PROVISIONER_IMAGE: "{provisioner}"\n'
    f'  ROOK_CSI_SNAPSHOTTER_IMAGE: "{snapshotter}"\n'
    f'  ROOK_CSI_ATTACHER_IMAGE: "{attacher}"\n'
)
content = content.replace(anchor, inject, 1)

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

print_pods() {
  kubectl -n "${ROOK_NAMESPACE}" get pods -o wide 2>/dev/null || true
}

first_bad_pod() {
  kubectl -n "${ROOK_NAMESPACE}" get pods --no-headers 2>/dev/null \
    | awk '$3 ~ /ErrImagePull|ImagePullBackOff|Init:ErrImagePull|Init:ImagePullBackOff|CrashLoopBackOff/ {print $1; exit}'
}

fail_on_bad_pod() {
  local pod
  pod="$(first_bad_pod || true)"
  if [[ -n "${pod}" ]]; then
    error "Pod ${pod} bi loi trong namespace ${ROOK_NAMESPACE}."
    kubectl -n "${ROOK_NAMESPACE}" describe pod "${pod}" || true
    exit 1
  fi
}

wait_for_deployment() {
  local name=$1
  local timeout=${2:-$WAIT_TIMEOUT}
  log "Doi deployment/${name} ready (${timeout}s)..."
  kubectl -n "${ROOK_NAMESPACE}" rollout status "deployment/${name}" --timeout="${timeout}s"
}

wait_for_labeled_pod_ready() {
  local selector=$1
  local title=$2
  local timeout=$3
  local elapsed=0

  log "Doi ${title} (${timeout}s)..."
  while (( elapsed < timeout )); do
    fail_on_bad_pod

    if kubectl -n "${ROOK_NAMESPACE}" get pods -l "${selector}" --no-headers 2>/dev/null | grep -q .; then
      if kubectl -n "${ROOK_NAMESPACE}" wait pod -l "${selector}" --for=condition=Ready --timeout=20s >/dev/null 2>&1; then
        log "${title} ready"
        return 0
      fi
    fi

    sleep 10
    elapsed=$((elapsed + 10))
  done

  warn "${title} timeout sau ${timeout}s"
  print_pods
  fail_on_bad_pod
  return 1
}

wait_for_any_running_pod() {
  local selector=$1
  local title=$2
  local timeout=$3
  local elapsed=0

  log "Doi ${title} co pod Running (${timeout}s)..."
  while (( elapsed < timeout )); do
    fail_on_bad_pod

    if kubectl -n "${ROOK_NAMESPACE}" get pods -l "${selector}" --no-headers 2>/dev/null | awk '$3 == "Running" {found=1} END {exit(found?0:1)}'; then
      log "${title} da co pod Running"
      return 0
    fi

    sleep 10
    elapsed=$((elapsed + 10))
  done

  warn "${title} timeout sau ${timeout}s"
  print_pods
  fail_on_bad_pod
  return 1
}

verify_cluster_access() {
  require_cmd kubectl
  require_cmd curl
  require_cmd python3

  if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Khong ket noi duoc cluster. Kiem tra kubeconfig."
    exit 1
  fi

  local ready total
  ready="$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  total="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"

  log "Nodes: ${ready}/${total} Ready"
  kubectl get nodes -o wide

  if [[ "${ready}" -lt 2 ]]; then
    error "Can it nhat 2 node Ready de chay Ceph."
    exit 1
  fi
}

apply_operator_stack() {
  local operator_manifest
  operator_manifest="$(render_operator_manifest)"

  log "==> [1/4] Cai Rook Operator (${ROOK_VERSION})"
  log "Apply CRDs..."
  kubectl apply --server-side -f "${ROOK_BASE}/crds.yaml"

  log "Apply common resources..."
  kubectl apply -f "${ROOK_BASE}/common.yaml"

  log "Apply operator..."
  kubectl apply -f "${operator_manifest}"

  wait_for_deployment "rook-ceph-operator" "${WAIT_TIMEOUT}"
}

apply_cluster() {
  local cluster_manifest
  cluster_manifest="$(render_cluster_manifest)"

  log "==> [2/4] Deploy CephCluster"
  kubectl apply -f "${cluster_manifest}"

  log "Theo doi cluster bootstrap..."
  sleep 10
  fail_on_bad_pod

  wait_for_labeled_pod_ready "app=rook-ceph-mon" "MON pods" 600 || true
  wait_for_labeled_pod_ready "app=rook-ceph-mgr" "MGR pod" 300 || true
  wait_for_any_running_pod "app=rook-ceph-osd" "OSD pods" 600 || true

  print_pods
}

apply_storageclasses() {
  log "==> [3/4] Tao StorageClass (RBD + CephFS)"
  kubectl apply -f "${MANIFEST_DIR}/storageclass.yaml"
  log "Doi CephBlockPool va CephFilesystem tao xong (60s)..."
  sleep 60
  kubectl get sc
}

verify_cluster() {
  local toolbox_manifest
  toolbox_manifest="$(render_toolbox_manifest)"

  log "==> [4/4] Verify cluster"
  log "Deploy toolbox..."
  kubectl apply -f "${toolbox_manifest}"
  kubectl -n "${ROOK_NAMESPACE}" rollout status deployment/rook-ceph-tools --timeout=120s >/dev/null 2>&1 || true

  sleep 10
  fail_on_bad_pod

  log "Pods:"
  print_pods

  log "Ceph status:"
  kubectl -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- ceph status 2>/dev/null \
    || warn "Toolbox chua ready hoan toan. Kiem tra sau bang: kubectl -n ${ROOK_NAMESPACE} exec deploy/rook-ceph-tools -- ceph status"
}

print_summary() {
  local dashboard_pass
  dashboard_pass="$(kubectl -n "${ROOK_NAMESPACE}" get secret rook-ceph-dashboard-password \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<chua co>")"

  log ""
  log "Rook-Ceph da cai xong"
  log ""
  log "StorageClass:"
  kubectl get sc
  log ""
  log "Dashboard:"
  log "  kubectl -n ${ROOK_NAMESPACE} port-forward svc/rook-ceph-mgr-dashboard 8443:8443"
  log "  Truy cap: https://localhost:8443"
  log "  User: admin / Pass: ${dashboard_pass}"
  log ""
  log "Lenh huu ich:"
  log "  Trang thai:  sudo ./scripts/status.sh"
  log "  Ceph CLI:    kubectl -n ${ROOK_NAMESPACE} exec deploy/rook-ceph-tools -- ceph status"
  log "  Teardown:    sudo ./scripts/teardown.sh"
}

main() {
  print_header
  verify_cluster_access
  apply_operator_stack
  apply_cluster
  apply_storageclasses
  verify_cluster
  print_summary
}

main "$@"
