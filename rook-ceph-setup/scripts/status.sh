#!/usr/bin/env bash
# status.sh — Xem trạng thái Rook-Ceph cluster
set -euo pipefail
YELLOW='\033[1;33m'; NC='\033[0m'
section() { echo -e "\n${YELLOW}===== $* =====${NC}"; }

section "Nodes"
kubectl get nodes -o wide

section "Rook Pods"
kubectl -n rook-ceph get pods -o wide

section "StorageClasses"
kubectl get sc

section "PVC"
kubectl get pvc -A

section "Ceph Status (via toolbox)"
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status 2>/dev/null \
  || echo "(toolbox chưa ready)"

section "OSD Tree"
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree 2>/dev/null \
  || echo "(toolbox chưa ready)"

section "Pool Usage"
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph df 2>/dev/null \
  || echo "(toolbox chưa ready)"
