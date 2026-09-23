#!/usr/bin/env bash
# 01-lay-rootfs.sh —— 把 Frame 的 rootfs 铺进我们自己的 ext4 镜像
# 用法: sudo scripts/host/01-lay-rootfs.sh <frame_rootfs.raw> <rootfs.img> <大小,如 12G>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "需要 root"
SRC="${1:?用法: 01-lay-rootfs.sh <frame_rootfs.raw> <rootfs.img> <size>}"
IMG="${2:?}"
SIZE="${3:-12G}"
MOUNT_SRC=/mnt/frame-src
MOUNT_DST=/mnt/rootfs

mkdir -p "$MOUNT_SRC" "$MOUNT_DST"
umount "$MOUNT_SRC" 2>/dev/null || true
umount "$MOUNT_DST" 2>/dev/null || true
mount -o loop,ro "$SRC" "$MOUNT_SRC" || die "挂载 Frame rootfs 失败（不是 ext4？）"

log "创建 $SIZE 的 ext4 镜像 $IMG"
rm -f "$IMG"; truncate -s "$SIZE" "$IMG"; mkfs.ext4 -q -F -L rootfs "$IMG"
mount -o loop "$IMG" "$MOUNT_DST" || die "挂载新镜像失败"

log "rsync Frame userspace → 我们的镜像（保留权限/硬链接/xattr）"
rsync -aHAX --numeric-ids --info=progress2 \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/var/cache/pacman/pkg/*' \
  "$MOUNT_SRC/" "$MOUNT_DST/"

# Frame 是 ESP/UEFI + A/B 槽，这些对我们无用且会干扰
log "清理 Frame 专属引导/槽位残留"
rm -rf "$MOUNT_DST"/boot/* "$MOUNT_DST"/usr/lib/modules/* 2>/dev/null || true
rm -f "$MOUNT_DST"/etc/fstab
for u in steamos-manager steamos-update atomupd rauc bootc; do
  rm -f "$MOUNT_DST/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || true
done

sync
umount "$MOUNT_DST"; umount "$MOUNT_SRC"
log "已铺好: $IMG"