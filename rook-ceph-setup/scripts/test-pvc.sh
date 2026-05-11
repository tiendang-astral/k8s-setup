#!/usr/bin/env bash
#
# test-pvc.sh — Test tạo PVC và pod mount để verify Rook hoạt động
#
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

log "==> Test RBD (Block) PVC"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-rbd-pvc
spec:
  storageClassName: rook-ceph-block
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-rbd-pod
spec:
  containers:
    - name: test
      image: busybox:stable
      command: [sh, -c, "echo 'RBD OK' > /mnt/test.txt && cat /mnt/test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /mnt
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-rbd-pvc
EOF

log "Đợi PVC bound và pod running (120s)..."
kubectl wait pvc/test-rbd-pvc --for=jsonpath='{.status.phase}'=Bound --timeout=120s \
  && log "✅ RBD PVC Bound!" \
  || warn "RBD PVC chưa Bound. Check: kubectl describe pvc test-rbd-pvc"

kubectl wait pod/test-rbd-pod --for=condition=Ready --timeout=120s \
  && log "✅ RBD Pod Running!" \
  || warn "Pod chưa ready."

log "Output từ pod:"
kubectl logs test-rbd-pod 2>/dev/null | head -5 || true

log ""
log "==> Dọn dẹp test resources"
kubectl delete pod test-rbd-pod --ignore-not-found
kubectl delete pvc test-rbd-pvc --ignore-not-found

log "Test xong ✅"
