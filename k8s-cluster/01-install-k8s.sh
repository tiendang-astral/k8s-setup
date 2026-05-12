#!/usr/bin/env bash
#
# 01-install-k8s.sh
# Cài đặt kubeadm, kubelet, kubectl từ repo chính thức của Kubernetes
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

# Phiên bản Kubernetes muốn cài (chỉnh sửa nếu cần)
K8S_VERSION="${K8S_VERSION:-v1.36.0}"

log "==> Cài đặt Kubernetes ${K8S_VERSION}"

log "==> [1/4] Thêm GPG key của Kubernetes"
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

log "==> [2/4] Thêm Kubernetes apt repo"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
chmod 644 /etc/apt/sources.list.d/kubernetes.list

log "==> [3/4] Cài kubelet, kubeadm, kubectl"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

log "==> [4/4] Enable kubelet"
systemctl enable --now kubelet

log "✅ Đã cài xong:"
kubeadm version -o short
kubectl version --client -o yaml | grep gitVersion | head -1
kubelet --version

log ""
log "Bước tiếp theo:"
log "  - Trên MASTER node:  sudo ./scripts/02-init-master.sh"
log "  - Trên WORKER node:  sudo ./scripts/03-join-worker.sh '<lệnh kubeadm join...>'"
