#!/usr/bin/env bash
#
# 02-init-master.sh
# Khởi tạo control-plane (master) node bằng kubeadm + cài CNI
#
# Env vars có thể chỉnh:
#   POD_CIDR              - dải IP cho pod network (default: 10.244.0.0/16)
#   SERVICE_CIDR          - dải IP cho service (default: 10.96.0.0/12)
#   APISERVER_ADVERTISE   - IP api-server sẽ advertise (default: IP mặc định của host)
#   CONTROL_PLANE_ENDPOINT- endpoint HA (vd: k8s-api.example.com:6443). Để trống nếu không HA.
#   CNI                   - calico | flannel (default: calico)
#   CALICO_VERSION        - version Calico (default: v3.28.0)
#   CALICO_IMAGE_REGISTRY - registry thay thế cho image Calico (default: quay.io)
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  error "Phải chạy với quyền root: sudo $0"
  exit 1
fi

# ============================================================
# Cấu hình
# ============================================================
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
APISERVER_ADVERTISE="${APISERVER_ADVERTISE:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
CNI="${CNI:-calico}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.0}"
CALICO_IMAGE_REGISTRY="${CALICO_IMAGE_REGISTRY:-quay.io}"

# Tên user thường (không phải root) để copy kubeconfig về
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

log "Cấu hình cluster:"
log "  POD_CIDR              = ${POD_CIDR}"
log "  SERVICE_CIDR          = ${SERVICE_CIDR}"
log "  APISERVER_ADVERTISE   = ${APISERVER_ADVERTISE}"
log "  CONTROL_PLANE_ENDPOINT= ${CONTROL_PLANE_ENDPOINT:-<không có>}"
log "  CNI                   = ${CNI}"
log "  CALICO_IMAGE_REGISTRY = ${CALICO_IMAGE_REGISTRY}"
log "  TARGET_USER           = ${TARGET_USER}"
echo

# ============================================================
# BƯỚC 1: Pull control-plane images
# ============================================================
log "==> [1/5] Pull control-plane images"
kubeadm config images pull --cri-socket=unix:///run/containerd/containerd.sock

# ============================================================
# BƯỚC 2: kubeadm init
# ============================================================
log "==> [2/5] Chạy kubeadm init"
KUBEADM_ARGS=(
  --pod-network-cidr="${POD_CIDR}"
  --service-cidr="${SERVICE_CIDR}"
  --apiserver-advertise-address="${APISERVER_ADVERTISE}"
  --cri-socket=unix:///run/containerd/containerd.sock
)
if [[ -n "${CONTROL_PLANE_ENDPOINT}" ]]; then
  KUBEADM_ARGS+=(--control-plane-endpoint="${CONTROL_PLANE_ENDPOINT}" --upload-certs)
fi

kubeadm init "${KUBEADM_ARGS[@]}" | tee /var/log/kubeadm-init.log

# ============================================================
# BƯỚC 3: Cấu hình kubectl
# ============================================================
log "==> [3/5] Cấu hình kubectl cho user ${TARGET_USER}"
if [[ "${TARGET_USER}" != "root" ]]; then
  USER_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
  mkdir -p "${USER_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
  chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.kube"
fi
# Cho cả root
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf

# ============================================================
# BƯỚC 4: Cài CNI
# ============================================================
log "==> [4/5] Cài CNI plugin: ${CNI}"
case "${CNI}" in
  calico)
    log "Cài Calico ${CALICO_VERSION} từ ${CALICO_IMAGE_REGISTRY}"
    CALICO_MANIFEST="/tmp/calico-${CALICO_VERSION}.yaml"
    curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o "${CALICO_MANIFEST}"
    sed -i "s|docker.io/|${CALICO_IMAGE_REGISTRY%/}/|g" "${CALICO_MANIFEST}"
    kubectl apply -f "${CALICO_MANIFEST}"
    ;;
  flannel)
    log "Cài Flannel"
    kubectl apply -f "https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
    ;;
  *)
    error "CNI không hỗ trợ: ${CNI}. Dùng 'calico' hoặc 'flannel'."
    exit 1
    ;;
esac

log "Đợi pod CNI sẵn sàng (timeout 5 phút)..."
sleep 5
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s || warn "Một số pod chưa Ready, kiểm tra lại bằng: kubectl get pods -n kube-system"

kubectl get pods -n kube-system

# ============================================================
# BƯỚC 5: Tạo lệnh join cho worker
# ============================================================
log "==> [5/5] Tạo lệnh join cho worker"
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "${JOIN_CMD}" > /root/kubeadm-join-command.sh
chmod +x /root/kubeadm-join-command.sh

# ============================================================
# Kết thúc
# ============================================================
log ""
log "✅ Master node đã sẵn sàng!"
log ""
log "Kiểm tra trạng thái:"
log "  kubectl get nodes"
log "  kubectl get pods -A"
log ""
log "Lệnh join cho worker (đã lưu vào /root/kubeadm-join-command.sh):"
echo -e "${YELLOW}${JOIN_CMD}${NC}"
log ""
log "Chạy lệnh trên ở mỗi worker node (sau khi đã chạy 00-common.sh + 01-install-k8s.sh)."
