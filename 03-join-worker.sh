#!/usr/bin/env bash
#
# 03-join-worker.sh
# Join worker node vào cluster
#
# Cách dùng:
#   sudo ./03-join-worker.sh "kubeadm join 10.0.0.1:6443 --token xxx --discovery-token-ca-cert-hash sha256:yyy"
#
# Lệnh join lấy từ output của 02-init-master.sh, hoặc trên master chạy:
#   sudo kubeadm token create --print-join-command
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  error "Phải chạy với quyền root: sudo $0 \"<lệnh kubeadm join...>\""
  exit 1
fi

if [[ $# -lt 1 ]]; then
  error "Thiếu lệnh join. Cách dùng:"
  error "  sudo $0 \"kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>\""
  exit 1
fi

JOIN_CMD="$*"

# Đảm bảo có --cri-socket
if [[ "${JOIN_CMD}" != *"--cri-socket"* ]]; then
  JOIN_CMD="${JOIN_CMD} --cri-socket=unix:///run/containerd/containerd.sock"
fi

log "==> Đang join cluster..."
log "Lệnh: ${JOIN_CMD}"
eval "${JOIN_CMD}"

log ""
log "✅ Worker node đã join cluster!"
log "Trên master, kiểm tra: kubectl get nodes"
