# rook-ceph-setup

Cài Rook-Ceph vào K8s cluster hiện có bằng 1 lệnh.

## Stack

- **Rook**: v1.14.9
- **Ceph**: Reef (v18.2.4)
- **OSD disk**: Loop device (lab) hoặc raw disk (production)
- **StorageClass**: `rook-ceph-block` (RWO, default) + `rook-cephfs` (RWX)

## Yêu cầu

- K8s cluster đang chạy (master + ≥2 worker)
- `kubectl` hoạt động trên master
- SSH từ master tới worker bằng root (để tạo loop device)
- Mỗi worker: ≥4GB RAM, ≥2 CPU

## Cách dùng

### All-in-one (1 lệnh)

```bash
git clone <repo> rook-ceph-setup
cd rook-ceph-setup
chmod +x setup-rook.sh scripts/*.sh

# Thay IP worker của bạn
sudo WORKER_NODES="192.168.64.11,192.168.64.12" ./setup-rook.sh
```

Script sẽ tự động:
1. SSH vào từng worker → tạo loop device `/dev/loop200` (10GB)
2. Cài Rook operator vào namespace `rook-ceph`
3. Deploy CephCluster
4. Tạo StorageClass `rook-ceph-block` (default) + `rook-cephfs`
5. Test tạo PVC để verify

### Chạy từng bước

```bash
# Bước 1: Trên TỪNG worker node — tạo OSD disk
sudo ./scripts/00-prepare-nodes.sh

# Bước 2: Trên master — cài Rook
sudo SKIP_PREPARE=1 ./scripts/01-install-rook.sh

# Bước 3: Test
sudo ./scripts/test-pvc.sh
```

---

## Tuỳ chỉnh

```bash
# Đổi version Rook
sudo ROOK_VERSION=v1.14.0 WORKER_NODES="..." ./setup-rook.sh

# Đổi size OSD disk (GB)
sudo OSD_IMG_SIZE=20 ./scripts/00-prepare-nodes.sh

# Đổi loop device (nếu loop200 bị dùng rồi)
sudo OSD_LOOP_DEV=/dev/loop201 ./scripts/00-prepare-nodes.sh

# Bỏ qua prepare (đã làm rồi)
sudo SKIP_PREPARE=1 ./setup-rook.sh
```

---

## Cấu trúc repo

```
rook-ceph-setup/
├── README.md
├── setup-rook.sh                     # All-in-one
├── manifests/
│   ├── cluster.yaml                  # CephCluster (tuỳ chỉnh cho loop device)
│   └── storageclass.yaml             # RBD + CephFS StorageClass
└── scripts/
    ├── 00-prepare-nodes.sh           # Tạo OSD loop device trên worker
    ├── 01-install-rook.sh            # Cài operator + cluster + SC
    ├── status.sh                     # Trạng thái cluster
    ├── test-pvc.sh                   # Test tạo PVC
    └── teardown.sh                   # Gỡ hoàn toàn Rook-Ceph
```

---

## Thứ tự chạy thủ công

| Nơi chạy | Script |
|----------|--------|
| Từng **worker** | `00-prepare-nodes.sh` |
| **Master** | `01-install-rook.sh` (với `SKIP_PREPARE=1`) |
| **Master** | `test-pvc.sh` |

---

## Lệnh hay dùng

```bash
# Trạng thái tổng quan
sudo ./scripts/status.sh

# Ceph CLI
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph df

# Dashboard (mở tunnel trên máy local)
kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 8443:8443
# Truy cập: https://localhost:8443
# Pass: kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d

# Xem PVC toàn cluster
kubectl get pvc -A

# Gỡ cài đặt
sudo ./scripts/teardown.sh
```

---

## Troubleshooting

**OSD pod không lên:**
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare -c provision-osd --tail=50
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
```

**Ceph HEALTH_WARN:**
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail
```

**PVC stuck Pending:**
```bash
kubectl describe pvc <pvc-name>
# Thường do OSD chưa up hoặc pool chưa tạo xong
```

**Loop device mất sau reboot:**
```bash
# Trên node bị mất
sudo systemctl start rook-osd-loop
sudo systemctl status rook-osd-loop
```

---

## Lưu ý

- Loop device là **giả lập** — không dùng cho production. Production cần raw disk (`/dev/sdb`, `/dev/nvme0n1`, v.v.)
- Replication mặc định = 2 (cần ≥2 node). Đổi sang 3 trong `manifests/cluster.yaml` và `manifests/storageclass.yaml` khi có ≥3 node.
- `rook-ceph-block` được set làm **default StorageClass** — thay thế `local-path` nếu đang dùng.
