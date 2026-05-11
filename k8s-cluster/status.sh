#!/usr/bin/env bash
#
# status.sh
# Kiểm tra nhanh trạng thái cluster (chạy trên master)
#
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
section() { echo -e "\n${YELLOW}===== $* =====${NC}"; }

if [[ -f /etc/kubernetes/admin.conf && $EUID -eq 0 ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

section "Nodes"
kubectl get nodes -o wide

section "System Pods"
kubectl get pods -n kube-system -o wide

section "Cluster Info"
kubectl cluster-info

section "Component Health"
kubectl get --raw='/readyz?verbose' 2>/dev/null | head -30 || echo "(không lấy được)"

section "Tài nguyên trên các node"
kubectl top nodes 2>/dev/null || echo "(cần metrics-server, bỏ qua)"
