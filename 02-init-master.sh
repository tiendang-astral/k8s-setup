#!/usr/bin/env bash
#
# 02-init-master.sh
# Khởi tạo control-plane (master) node bằng kubeadm
#
# Env vars có thể chỉnh:
#   POD_CIDR              - dải IP cho pod network (default: 10.244.0.0/16)
#   SERVICE_CIDR          - dải IP cho service (default: 10.96.0.0/12)
#   APISERVER_ADVERTISE   - IP api-server sẽ advertise (default: IP mặc định của host)
#   CONTROL_PLANE_ENDPOINT- endpoint HA (vd: k8s-api.example.com:6443). Để trống nếu không HA.
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

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
APISERVER_ADVERTISE="${APISERVER_ADVERTISE:-$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"

# Tên user thường (không phải root) để copy kubeconfig về
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

log "Cấu hình cluster:"
log "  POD_CIDR              = ${POD_CIDR}"
log "  SERVICE_CIDR          = ${SERVICE_CIDR}"
log "  APISERVER_ADVERTISE   = ${APISERVER_ADVERTISE}"
log "  CONTROL_PLANE_ENDPOINT= ${CONTROL_PLANE_ENDPOINT:-<không có>}"
log "  TARGET_USER           = ${TARGET_USER}"
echo

log "==> [1/4] Pull control-plane images"
kubeadm config images pull

log "==> [2/4] Chạy kubeadm init"
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

log "==> [3/4] Cấu hình kubectl cho user ${TARGET_USER}"
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

log "==> [4/4] Cài CNI plugin (Calico)"
"$(dirname "$0")/04-install-cni.sh"

# Lưu lệnh join để worker dùng
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "${JOIN_CMD}" > /root/kubeadm-join-command.sh
chmod +x /root/kubeadm-join-command.sh

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
