#!/usr/bin/env bash
#
# 00-prepare-nodes.sh
# Tạo loop device OSD trên TẤT CẢ worker node (chạy trên TỪNG node)
#
# Rook-Ceph cần raw/unformatted disk. Script này tạo loop device
# giả lập raw disk từ file image.
#
# Env vars:
#   OSD_IMG_PATH  - Path file image (default: /var/lib/rook-osd.img)
#   OSD_IMG_SIZE  - Size GB (default: 10)
#   OSD_LOOP_DEV  - Loop device (default: /dev/loop200)
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Cần root: sudo $0"; exit 1; }

OSD_IMG_PATH="${OSD_IMG_PATH:-/var/lib/rook-osd.img}"
OSD_IMG_SIZE="${OSD_IMG_SIZE:-10}"
OSD_LOOP_DEV="${OSD_LOOP_DEV:-/dev/loop200}"

log "================================================="
log " Chuẩn bị OSD disk cho Rook-Ceph"
log "  Node:         $(hostname)"
log "  OSD_IMG_PATH: ${OSD_IMG_PATH}"
log "  OSD_IMG_SIZE: ${OSD_IMG_SIZE}G"
log "  OSD_LOOP_DEV: ${OSD_LOOP_DEV}"
log "================================================="

# ============================================================
# BƯỚC 1: Cài packages cần thiết
# ============================================================
log "==> [1/4] Cài packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y lvm2 gdisk util-linux

# ============================================================
# BƯỚC 2: Tạo file image
# ============================================================
log "==> [2/4] Tạo OSD image file"
if [[ ! -f "${OSD_IMG_PATH}" ]]; then
  log "Tạo ${OSD_IMG_PATH} (${OSD_IMG_SIZE}GB)..."
  dd if=/dev/zero of="${OSD_IMG_PATH}" bs=1G count="${OSD_IMG_SIZE}" status=progress
  log "Tạo xong ✅"
else
  log "File đã tồn tại: ${OSD_IMG_PATH} ($(du -sh ${OSD_IMG_PATH} | cut -f1))"
fi

# ============================================================
# BƯỚC 3: Setup loop device
# ============================================================
log "==> [3/4] Setup loop device ${OSD_LOOP_DEV}"

# Detach nếu đang dùng
losetup -d "${OSD_LOOP_DEV}" 2>/dev/null || true

# Attach
losetup "${OSD_LOOP_DEV}" "${OSD_IMG_PATH}"

# Wipe filesystem signature (Rook cần disk sạch)
wipefs -af "${OSD_LOOP_DEV}" 2>/dev/null || true
dd if=/dev/zero of="${OSD_LOOP_DEV}" bs=1M count=10 2>/dev/null || true

log "Loop device OK: $(losetup -l ${OSD_LOOP_DEV})"

# ============================================================
# BƯỚC 4: Persist qua reboot
# ============================================================
log "==> [4/4] Cấu hình persist sau reboot"

# Tạo systemd service để mount loop device khi boot
cat > /etc/systemd/system/rook-osd-loop.service <<EOF
[Unit]
Description=Rook OSD Loop Device
After=local-fs.target
Before=kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/losetup ${OSD_LOOP_DEV} ${OSD_IMG_PATH}
ExecStop=/sbin/losetup -d ${OSD_LOOP_DEV}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rook-osd-loop.service
log "Systemd service enabled: rook-osd-loop"

log ""
log "✅ Node $(hostname) đã sẵn sàng!"
log "  OSD disk: ${OSD_LOOP_DEV}"
log ""
lsblk "${OSD_LOOP_DEV}"
