#!/usr/bin/env bash
#
# setup-master.sh
# All-in-one: chạy 1 lệnh duy nhất để dựng master node hoàn chỉnh
#
# Cách dùng:
#   sudo ./setup-master.sh
#
# Tuỳ chỉnh qua env (xem README):
#   K8S_VERSION, POD_CIDR, SERVICE_CIDR, APISERVER_ADVERTISE, CNI
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log()   { echo -e "${GREEN}[MASTER]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  error "Phải chạy với quyền root: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

log "==> Bước 1/3: Cài prerequisites"
bash "${SCRIPT_DIR}/scripts/00-common.sh"

log "==> Bước 2/3: Cài kubeadm/kubelet/kubectl"
bash "${SCRIPT_DIR}/scripts/01-install-k8s.sh"

log "==> Bước 3/3: Khởi tạo control-plane + CNI"
bash "${SCRIPT_DIR}/scripts/02-init-master.sh"

log ""
log "🎉 Master setup hoàn tất! Xem lệnh join ở phía trên hoặc /root/kubeadm-join-command.sh"
