#!/usr/bin/env bash
#
# 00-common.sh
# Cài đặt prerequisites cho TẤT CẢ các node (master + worker):
#   - Tắt swap
#   - Load kernel modules (overlay, br_netfilter)
#   - Cấu hình sysctl cho Kubernetes networking
#   - Cài đặt containerd làm container runtime
#   - Cấu hình SystemdCgroup cho containerd
#
# Tested on: Ubuntu 22.04 / 24.04
#
set -euo pipefail

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---- Phải chạy với quyền root ----
if [[ $EUID -ne 0 ]]; then
  error "Script này phải chạy với quyền root. Dùng: sudo $0"
  exit 1
fi

log "==> [1/6] Cập nhật apt và cài các gói cơ bản"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg gnupg lsb-release software-properties-common

log "==> [2/6] Tắt swap (yêu cầu bắt buộc của kubelet)"
swapoff -a
sed -i.bak -E 's@^([^#].*\sswap\s.*)$@#\1@g' /etc/fstab

log "==> [3/6] Load kernel modules cần thiết"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

log "==> [4/6] Cấu hình sysctl cho Kubernetes networking"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

log "==> [5/6] Cài đặt containerd"
if ! command -v containerd >/dev/null 2>&1; then
  apt-get install -y containerd
else
  log "containerd đã được cài, bỏ qua."
fi

log "==> [6/6] Cấu hình containerd (SystemdCgroup + registry mirror)"
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml


systemctl restart containerd
systemctl enable containerd

log "✅ Hoàn tất prerequisites. Tiếp theo chạy: ./scripts/01-install-k8s.sh"