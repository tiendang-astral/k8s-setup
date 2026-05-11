# k8s-cluster-setup

Bộ script tự động dựng Kubernetes cluster bằng `kubeadm` trên Ubuntu 22.04 / 24.04.
Chỉ cần SSH vào máy và chạy 1 lệnh duy nhất.

## Thành phần

- **Container runtime**: containerd (với SystemdCgroup)
- **Bootstrap**: kubeadm
- **CNI**: Calico (mặc định), có thể đổi sang Flannel
- **Metrics Server**: tự động thu thập tài nguyên cho `kubectl top`
- **Kubernetes version**: v1.30 (chỉnh được qua biến môi trường)

## Yêu cầu

Mỗi node cần:
- Ubuntu 22.04 hoặc 24.04 (64-bit)
- Tối thiểu 2 CPU, 2 GB RAM (master cần ≥ 2 CPU / 2 GB)
- Quyền `sudo` / root
- Kết nối internet
- Các node thông nhau qua mạng (mở port `6443`, `10250`, `30000-32767`, v.v.)
- Hostname duy nhất giữa các node

## Cách dùng nhanh

### 1. Trên MASTER node

```bash
git clone <repo-url> k8s-cluster-setup
cd k8s-cluster-setup
chmod +x setup-master.sh scripts/*.sh

sudo ./setup-master.sh
```

Cuối output sẽ in ra **lệnh `kubeadm join`** — copy lại để dùng cho worker.
Lệnh này cũng được lưu tại `/root/kubeadm-join-command.sh`.

### 2. Trên mỗi WORKER node

```bash
git clone <repo-url> k8s-cluster-setup
cd k8s-cluster-setup
chmod +x setup-worker.sh scripts/*.sh

sudo ./setup-worker.sh "kubeadm join 10.0.0.1:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:xxxxx"
```

### 3. Kiểm tra cluster (chạy trên master)

```bash
kubectl get nodes
./scripts/status.sh
```

## Tuỳ chỉnh qua biến môi trường

```bash
# Đổi version Kubernetes
sudo K8S_VERSION=v1.31 ./setup-master.sh

# Đổi pod CIDR (mặc định 10.244.0.0/16)
sudo POD_CIDR=192.168.0.0/16 ./setup-master.sh

# Đổi IP api-server advertise
sudo APISERVER_ADVERTISE=10.0.0.10 ./setup-master.sh

# Dùng Flannel thay vì Calico
sudo CNI=flannel ./setup-master.sh

# HA control-plane endpoint (load balancer)
sudo CONTROL_PLANE_ENDPOINT=k8s-api.example.com:6443 ./setup-master.sh
```

## Chạy từng bước (nếu cần kiểm soát)

```bash
sudo ./scripts/00-common.sh        # prerequisites (tất cả node)
sudo ./scripts/01-install-k8s.sh   # cài kubeadm/kubelet/kubectl (tất cả node)
sudo ./scripts/02-init-master.sh   # init control-plane (chỉ master)
sudo ./scripts/03-join-worker.sh "<lệnh join>"          # join (chỉ worker)
sudo ./scripts/04-install-cni.sh                        # cài CNI (đã được 02 gọi sẵn)
sudo ./scripts/04-install-metrics-server.sh             # cài Metrics Server (chỉ master, sau khi CNI ready)
```

## Reset / cài lại

Trên node muốn reset:

```bash
sudo ./scripts/reset.sh
```

Lệnh này sẽ:
- `kubeadm reset`
- xoá `/etc/kubernetes`, `/var/lib/kubelet`, `/etc/cni/net.d`, `~/.kube`
- flush iptables
- restart containerd

Sau đó có thể chạy lại `setup-master.sh` / `setup-worker.sh` từ đầu.

## Lấy lại lệnh join (nếu lỡ mất)

Trên master:

```bash
sudo kubeadm token create --print-join-command
```

## Cấu trúc repo

```
k8s-cluster-setup/
├── README.md
├── setup-master.sh           # All-in-one cho master
├── setup-worker.sh           # All-in-one cho worker
└── scripts/
    ├── 00-common.sh          # Prerequisites (swap, modules, sysctl, containerd)
    ├── 01-install-k8s.sh     # Cài kubeadm/kubelet/kubectl
    ├── 02-init-master.sh     # kubeadm init + cấu hình kubectl
    ├── 03-join-worker.sh     # kubeadm join
    ├── 04-install-cni.sh     # Cài Calico / Flannel
    ├── 04-install-metrics-server.sh   # Cài Metrics Server
    ├── reset.sh              # Reset cluster trên node
    └── status.sh             # Kiểm tra trạng thái
```

## Troubleshooting

**Pod CNI ở trạng thái `Pending` hoặc `CrashLoopBackOff`:**
- Đợi 2-3 phút cho image pull xong.
- Kiểm tra: `kubectl describe pod -n kube-system <pod-name>`

**Worker join thất bại:**
- Kiểm tra firewall mở port `6443` tới master.
- Token có thể đã hết hạn (24h) — tạo lại trên master:
  ```bash
  sudo kubeadm token create --print-join-command
  ```

**Node ở trạng thái `NotReady`:**
- Thường do CNI chưa cài/chưa chạy. Chạy:
  ```bash
  kubectl get pods -n kube-system
  ```

**Lỗi `cgroup driver`:**
- Đảm bảo `SystemdCgroup = true` trong `/etc/containerd/config.toml`.
- Restart: `sudo systemctl restart containerd kubelet`

## Lưu ý

- Đây là setup cho môi trường **dev / lab**. Cho production cần thêm: HA control-plane (3 master + load balancer), backup etcd, secrets management, network policy, RBAC, observability...
- Mặc định master có taint `node-role.kubernetes.io/control-plane:NoSchedule`. Nếu muốn schedule pod lên master (single-node cluster):
  ```bash
  kubectl taint nodes --all node-role.kubernetes.io/control-plane-
  ```
