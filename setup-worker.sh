#!/usr/bin/env bash
#
# setup-worker.sh
# All-in-one: chạy 1 lệnh duy nhất để dựng worker node và join cluster
#
# Cách dùng:
#   sudo ./setup-worker.sh "kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
#
# Lệnh join lấy từ master:
#   sudo kubeadm token create --print-join-command
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log()   { echo -e "${GREEN}[WORKER]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  error "Phải chạy với quyền root: sudo $0 \"<lệnh kubeadm join>\""
  exit 1
fi

if [[ $# -lt 1 ]]; then
  error "Thiếu lệnh join. Cách dùng:"
  error "  sudo $0 \"kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>\""
  exit 1
fi

JOIN_CMD="$*"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "==> Bước 1/3: Cài prerequisites"
bash "${SCRIPT_DIR}/scripts/00-common.sh"

log "==> Bước 2/3: Cài kubeadm/kubelet/kubectl"
bash "${SCRIPT_DIR}/scripts/01-install-k8s.sh"

log "==> Bước 3/3: Join cluster"
bash "${SCRIPT_DIR}/scripts/03-join-worker.sh" "${JOIN_CMD}"

log ""
log "🎉 Worker setup hoàn tất! Trên master kiểm tra: kubectl get nodes"
