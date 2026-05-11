#!/usr/bin/env bash
# =============================================================================
# DocFlow Platform — Kubernetes Deploy (Bare-metal / kubeadm cluster)
# =============================================================================
# Yêu cầu trước khi chạy:
#   - kubectl đã được cấu hình trỏ tới cluster (kubectl get nodes phải work)
#   - Cluster có ít nhất 1 node Ready
#   - Cluster có default StorageClass (script sẽ cảnh báo nếu thiếu)
#   - Image trong manifest có sẵn trên registry public (docker.io)
#
# Usage:
#   ./scripts/deploy-k8s.sh                     # full deploy
#   ./scripts/deploy-k8s.sh --skip-seed         # deploy không seed
#   ./scripts/deploy-k8s.sh --skip-prepull      # bỏ qua pre-pull image
#   DOCPROCESS_REPLICAS=5 ./scripts/deploy-k8s.sh
#   NAMESPACE=docflow ./scripts/deploy-k8s.sh   # deploy vào namespace khác
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

DEPLOY_DIR="deployment"
NAMESPACE="${NAMESPACE:-default}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse flags
SKIP_SEED=false
SKIP_PREPULL=false
for arg in "$@"; do
  case "$arg" in
    --skip-seed)    SKIP_SEED=true ;;
    --skip-prepull) SKIP_PREPULL=true ;;
  esac
done

KCTL="kubectl -n ${NAMESPACE}"

# =============================================================================
# STEP 1 – Pre-flight check
# =============================================================================
echo -e "\n${BOLD}=== Step 1: Pre-flight check ===${NC}\n"

if ! command -v kubectl &>/dev/null; then
  error "kubectl not found. Cài kubectl trước."
  exit 1
fi

# Check connectivity tới cluster
if ! kubectl cluster-info >/dev/null 2>&1; then
  error "Không kết nối được tới cluster. Kiểm tra:"
  error "  - File ~/.kube/config có đúng không"
  error "  - kubectl config current-context: $(kubectl config current-context 2>/dev/null || echo '<none>')"
  exit 1
fi

CTX=$(kubectl config current-context)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
success "Connected: context=${CTX}, server=${SERVER}"

# Check số node Ready
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [[ "${READY_NODES}" -lt 1 ]]; then
  error "Không có node nào Ready (${READY_NODES}/${TOTAL_NODES})."
  kubectl get nodes
  exit 1
fi
success "Nodes: ${READY_NODES}/${TOTAL_NODES} Ready"

# Tạo namespace nếu chưa có
if ! kubectl get ns "${NAMESPACE}" &>/dev/null; then
  info "Tạo namespace '${NAMESPACE}'"
  kubectl create namespace "${NAMESPACE}"
fi

# Check default StorageClass (database/MinIO dùng PVC)
DEFAULT_SC=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || true)
if [[ -z "${DEFAULT_SC}" ]]; then
  warn "Chưa có default StorageClass! PVC sẽ stuck ở Pending."
  warn "Cài local-path-provisioner để có default SC nhanh:"
  warn "  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
  warn "  kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=true"
  read -rp "Tiếp tục không? (yes/no): " confirm
  [[ "${confirm}" != "yes" ]] && exit 1
else
  success "Default StorageClass: ${DEFAULT_SC}"
fi

# Check ingress controller (chỉ cảnh báo)
if ! kubectl get pods -A 2>/dev/null | grep -qE "ingress-nginx|traefik|haproxy-ingress"; then
  warn "Không phát hiện ingress controller. Service sẽ access qua NodePort."
  warn "Nếu muốn dùng Ingress: kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml"
fi

# =============================================================================
# STEP 2 – Pre-pull images trên TẤT CẢ node (tuỳ chọn)
# =============================================================================
IMAGES=(
  "docker.io/duongnguyen291/docprocess-worker:prod"
  "docker.io/duongnguyen291/docflow-frontend:prod"
  "docker.io/duongnguyen291/docaiplatform-platform-worker:prod"
  "docker.io/duongnguyen291/docaiplatform-backend:prod"
)

if [[ "${SKIP_PREPULL}" == "false" ]]; then
  echo -e "\n${BOLD}=== Step 2: Pre-pulling images on all nodes ===${NC}\n"
  info "Tạo DaemonSet tạm để pull image trên mọi node (song song)..."

  # Sinh init container list
  INIT_CONTAINERS=""
  for i in "${!IMAGES[@]}"; do
    INIT_CONTAINERS+="
      - name: pull-${i}
        image: ${IMAGES[$i]}
        command: ['true']
        imagePullPolicy: IfNotPresent"
  done

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: image-prepull
  namespace: ${NAMESPACE}
spec:
  selector:
    matchLabels: { app: image-prepull }
  template:
    metadata:
      labels: { app: image-prepull }
    spec:
      tolerations:
        - operator: Exists
      initContainers:${INIT_CONTAINERS}
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources: { requests: { cpu: 10m, memory: 8Mi } }
EOF

  info "Đợi pre-pull hoàn tất (timeout 10 phút)..."
  if ${KCTL} rollout status ds/image-prepull --timeout=600s; then
    success "Images pulled trên tất cả node."
  else
    warn "Một số node pull image chậm/fail. Xem chi tiết:"
    warn "  ${KCTL} describe ds image-prepull"
    warn "  ${KCTL} get pods -l app=image-prepull -o wide"
    warn "Có thể tiếp tục — deployment sẽ tự pull khi cần."
  fi

  info "Xóa DaemonSet pre-pull..."
  ${KCTL} delete ds image-prepull --wait=false
else
  info "Step 2: Skip pre-pull (--skip-prepull)."
fi

# =============================================================================
# STEP 3 – Apply Database layer
# =============================================================================
echo -e "\n${BOLD}=== Step 3: Applying Database layer ===${NC}\n"

${KCTL} apply -f "${DEPLOY_DIR}/database/"

info "Đợi Postgres ready..."
${KCTL} rollout status statefulset/postgres --timeout=180s

info "Đợi Redis ready..."
${KCTL} rollout status statefulset/redis --timeout=180s

success "Database layer ready."

# =============================================================================
# STEP 4 – Apply MinIO
# =============================================================================
echo -e "\n${BOLD}=== Step 4: Applying MinIO ===${NC}\n"

${KCTL} apply -f "${DEPLOY_DIR}/min-io/01-min-io.config-map.yml"
${KCTL} apply -f "${DEPLOY_DIR}/min-io/02-min-io.secret.yml"
${KCTL} apply -f "${DEPLOY_DIR}/min-io/04-min-io.statefulset.yml"

info "Đợi MinIO ready..."
${KCTL} rollout status statefulset/minio --timeout=180s

info "Chạy MinIO init Job (bucket + CORS)..."
${KCTL} apply -f "${DEPLOY_DIR}/min-io/03-init.job.yml"
${KCTL} wait --for=condition=complete job/minio-init --timeout=300s 2>/dev/null || {
  warn "MinIO init job chưa xong. Check: ${KCTL} logs job/minio-init"
}

success "MinIO stack ready."

# =============================================================================
# STEP 5 – Apply Application
# =============================================================================
echo -e "\n${BOLD}=== Step 5: Applying Application ===${NC}\n"

DOCPROCESS_REPLICAS=${DOCPROCESS_REPLICAS:-3}

${KCTL} apply -f "${DEPLOY_DIR}/app/01-app.config-map.yml"
${KCTL} apply -f "${DEPLOY_DIR}/app/02-app.secret.yml"
${KCTL} apply -f "${DEPLOY_DIR}/app/03-app.pvc.yml"
${KCTL} apply -f "${DEPLOY_DIR}/app/04-docaiplatform-platform-worker.deployment.yml"
${KCTL} apply -f "${DEPLOY_DIR}/app/05-docprocess-worker.deployment.yml"
${KCTL} scale deployment/docprocess-worker --replicas="${DOCPROCESS_REPLICAS}"
info "Đã scale docprocess-worker thành ${DOCPROCESS_REPLICAS} replica(s)."

${KCTL} apply -f "${DEPLOY_DIR}/app/06-docaiplatform-backend.deployment.yml"
${KCTL} apply -f "${DEPLOY_DIR}/app/07-docaiplatform-frontend.deployment.yml"

info "Đợi tất cả deployment..."
${KCTL} rollout status deployment/docaiplatform-backend --timeout=300s
${KCTL} rollout status deployment/docaiplatform-frontend --timeout=300s
${KCTL} rollout status deployment/docaiplatform-platform-worker --timeout=300s
${KCTL} rollout status deployment/docprocess-worker --timeout=300s

success "Application stack ready."

# =============================================================================
# STEP 6 – Apply Monitoring
# =============================================================================
echo -e "\n${BOLD}=== Step 6: Applying Monitoring ===${NC}\n"

${KCTL} apply -f "${DEPLOY_DIR}/monitoring/"

info "Đợi Prometheus ready..."
${KCTL} rollout status deployment/prometheus --timeout=180s

info "Đợi Grafana ready..."
${KCTL} rollout status deployment/grafana --timeout=180s

success "Monitoring stack ready."

# =============================================================================
# STEP 7 – Post-deploy seed (tuỳ chọn)
# =============================================================================
if [[ "${SKIP_SEED}" == "false" ]]; then
  echo -e "\n${BOLD}=== Step 7: Running seed ===${NC}\n"

  BACKEND_POD=$(${KCTL} get pods -l app=docaiplatform-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "${BACKEND_POD}" ]]; then
    info "Tạo demo users..."
    ${KCTL} exec "${BACKEND_POD}" -- python backend/scripts/create_demo_users.py \
      && success "Demo users created." \
      || warn "create_demo_users.py có lỗi (có thể đã tồn tại)."
  else
    warn "Không tìm thấy backend pod. Skip seed."
  fi
else
  warn "--skip-seed: skip seed."
fi

# =============================================================================
# Summary
# =============================================================================
echo -e "\n${BOLD}${GREEN}=== Deploy complete ===${NC}\n"

${KCTL} get pods -o wide

# Lấy IP của 1 node để hiển thị access point
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')

echo ""
info "Access points (NodePort — dùng IP của BẤT KỲ node nào):"
echo "  Frontend       : http://${NODE_IP}:30000"
echo "  Backend API    : http://${NODE_IP}:30001/health"
echo "  Grafana        : http://${NODE_IP}:30002 (admin / <GRAFANA_ADMIN_PASSWORD>)"
echo "  MinIO API      : http://${NODE_IP}:30003"
echo "  MinIO Console  : http://${NODE_IP}:30004"
echo ""
info "Liệt kê IP của tất cả node để chọn:"
kubectl get nodes -o wide --no-headers | awk '{printf "  %-20s %s\n", $1, $6}'
echo ""
info "Lệnh hữu ích:"
echo "  Logs (backend) : ${KCTL} logs -l app=docaiplatform-backend -f"
echo "  Pods status    : ${KCTL} get pods -o wide"
echo "  Mô tả node     : kubectl describe node <node-name>"
echo "  Teardown       : bash scripts/down-k8s.sh"
echo ""
info "Nếu muốn dùng port-forward thay NodePort:"
echo "  ${KCTL} port-forward svc/docaiplatform-frontend 30000:<port>"