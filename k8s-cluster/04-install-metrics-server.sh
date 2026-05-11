#!/usr/bin/env bash
#
# 04-install-metrics-server.sh
# Cài đặt Metrics Server trên master node
# Cho phép lệnh kubectl top (nodes / pods) hoạt động
#
# Yêu cầu: chạy sau khi kubeadm init và CNI đã sẵn sàng
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

if [[ -f /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

log "==> [1/4] Kiểm tra kết nối cluster"
if ! kubectl cluster-info >/dev/null 2>&1; then
  error "Không thể kết nối cluster. Kiểm tra kubeconfig."
  exit 1
fi
log "Cluster đang hoạt động."

log "==> [2/4] Apply Metrics Server manifest"
kubectl apply -f "$(dirname "$0")/metric-server.yml"

log "==> [3/4] Chờ Metrics Server sẵn sàng"
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=180s

log "==> [4/4] Kiểm tra Metrics Server"
kubectl get pods -n kube-system -l k8s-app=metrics-server

log ""
log "✅ Metrics Server đã sẵn sàng!"
log ""
log "Kiểm tra:"
log "  kubectl top nodes"
log "  kubectl top pods -A"
log ""
log "Lưu ý: Có thể mất 1-2 phút để metrics được thu thập."
log "  Nếu 'kubectl top nodes' chưa ra số liệu, hãy đợi và chạy lại."
