#!/usr/bin/env bash
#
# reset.sh
# Reset cluster trên node hiện tại (XÓA TOÀN BỘ k8s state)
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

warn "⚠️  Cảnh báo: thao tác này sẽ XÓA TOÀN BỘ trạng thái Kubernetes trên node này!"
read -rp "Gõ 'yes' để xác nhận: " confirm
if [[ "${confirm}" != "yes" ]]; then
  log "Đã hủy."
  exit 0
fi

log "==> kubeadm reset"
kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock || true

log "==> Xóa cấu hình CNI và network"
rm -rf /etc/cni/net.d
rm -rf /var/lib/cni/
rm -rf /var/lib/kubelet/*
rm -rf /etc/kubernetes/
rm -rf "$HOME/.kube"
[[ -n "${SUDO_USER:-}" ]] && rm -rf "/home/${SUDO_USER}/.kube"

log "==> Flush iptables"
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true

log "==> Reload containerd"
systemctl restart containerd || true

log "✅ Đã reset xong. Có thể chạy lại setup từ đầu."
