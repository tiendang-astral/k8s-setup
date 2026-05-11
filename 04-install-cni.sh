#!/usr/bin/env bash
#
# 04-install-cni.sh
# Cài đặt CNI plugin. Mặc định dùng Calico, có thể đổi sang Flannel qua env CNI=flannel
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

CNI="${CNI:-calico}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.0}"

# Tìm kubeconfig
if [[ -f /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
elif [[ -f "$HOME/.kube/config" ]]; then
  export KUBECONFIG="$HOME/.kube/config"
else
  error "Không tìm thấy kubeconfig. Đã chạy kubeadm init chưa?"
  exit 1
fi

case "${CNI}" in
  calico)
    log "==> Cài Calico ${CALICO_VERSION}"
    kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
    ;;
  flannel)
    log "==> Cài Flannel"
    kubectl apply -f "https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
    ;;
  *)
    error "CNI không hỗ trợ: ${CNI}. Dùng 'calico' hoặc 'flannel'."
    exit 1
    ;;
esac

log "==> Đợi pod CNI sẵn sàng (timeout 5 phút)..."
sleep 5
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s || true

log "✅ Đã cài CNI: ${CNI}"
kubectl get pods -n kube-system
