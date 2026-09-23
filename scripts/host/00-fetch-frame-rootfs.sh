#!/usr/bin/env bash
# 00-fetch-frame-rootfs.sh —— 取 Steam Frame 官方镜像并解出真正的 rootfs
#
# 底包形态（实测 20260922.5153644-0.3.0）：
#   .img.bz2  →  bz2 里是 7 GB 的 **GPT 整盘镜像**，5 个分区：
#       0.esp.img(256M) / 1.efi-A.fat(64M) / 2.rootfs-A.img(5G) / 3.var-A.img(256M) / 4.home.img(100M)
#   而 2.rootfs-A.img 前 5 MiB 是保留区，之后是 **zstd 压缩流**（不是裸 ext4），
#   7-Zip 解不动它（多帧 zstd），必须用 zstd 本体。
#
# 本脚本产出：$OUT/rootfs.raw（Frame 的 userspace ext4/镜像）+ $OUT/frame-os-release
#
# 环境变量：
#   FRAME_IMAGE_URL  默认官方 steamframe-repair-latest.img.bz2（公开可直连）
#   WORK             工作目录（默认 /mnt/frame-work，需 ≥ 20 GB 空闲）
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

FRAME_IMAGE_URL="${FRAME_IMAGE_URL:-https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2}"
WORK="${WORK:-/mnt/frame-work}"
OUT="${OUT:-$WORK/out}"
sudo mkdir -p "$WORK" "$OUT"
command -v zstd >/dev/null || die "需要 zstd（Ubuntu runner: apt-get install zstd xz-utils）"

BZ="$WORK/frame.img.bz2"
IMG="$WORK/frame.img"

# 1) 下载（支持复用已下载文件）
if [[ ! -s "$BZ" ]]; then
  log "下载底包: $FRAME_IMAGE_URL"
  curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$BZ.part" "$FRAME_IMAGE_URL" || die "下载失败"
  mv -f "$BZ.part" "$BZ"
fi
log "底包大小: $(du -h "$BZ" | cut -f1)"

# 2) bz2 解压出整盘镜像（bz2 是单文件流，用 bunzip2 -c 流式写）
if [[ ! -s "$IMG" ]]; then
  log "解压 bz2 → 整盘镜像（约 7 GB，慢）"
  bunzip2 -c "$BZ" > "$IMG" || die "bunzip2 失败"
fi
log "整盘镜像: $(du -h "$IMG" | cut -f1)"

# 3) 用 loop 设备暴露分区表，取 rootfs 分区（第 2 分区）
LOOP="$(sudo losetup -Pf --show "$IMG")"
trap 'sudo umount "$WORK/mnt" 2>/dev/null || true; sudo losetup -d "$LOOP" 2>/dev/null || true' EXIT
PART="${LOOP}p2"
[[ -b "$PART" ]] || die "找不到 rootfs 分区 $PART"
log "rootfs 分区: $PART ($(sudo blockdev --getsize64 "$PART") 字节)"

# 4) 分区内前 5 MiB 是保留区，之后是 zstd 流：扫描 zstd 魔数定位真实偏移
#    （实测偏移 5246976 = 5 MiB + 4096，不写死，扫出来更稳）
log "扫描 zstd 魔数（28 B5 2F FD）"
OFF="$(sudo dd if="$PART" bs=1M count=8 status=none | od -An -tx1 -v \
       | tr -d ' \n' | grep -bo '28b52ffd' | head -n1 | cut -d: -f1 || true)"
[[ -n "${OFF:-}" ]] || die "前 8 MB 内没有 zstd 魔数，底包结构可能变了"
OFF=$(( OFF / 2 ))          # od 给的是十六进制字符数 → 字节数
log "zstd 流起点: $OFF"

# 5) 切出 zstd 流并解压（zstd 自动处理多帧）
log "解出真正的 rootfs（zstd -d，约 5 GB）"
sudo dd if="$PART" bs=1M skip=$(( OFF / 1048576 )) status=none \
  | zstd -d -q -o "$OUT/rootfs.raw" -f || die "zstd 解压失败"
# 偏移不是整 MiB 时补掉余数
REM=$(( OFF % 1048576 ))
if [[ "$REM" -ne 0 ]]; then
  warn "偏移未对齐 MiB（余 $REM 字节），改用精确 dd"
  sudo dd if="$PART" bs=1 skip="$OFF" status=none | zstd -d -q -o "$OUT/rootfs.raw" -f || die "zstd 解压失败"
fi
log "rootfs 产出: $OUT/rootfs.raw ($(du -h "$OUT/rootfs.raw" | cut -f1))"

# 6) 挂起来核对（确认是 ext4 且能看到 os-release）
sudo mkdir -p "$WORK/mnt"
sudo mount -o loop,ro "$OUT/rootfs.raw" "$WORK/mnt" || die "挂载失败：可能不是 ext4（看 file 输出）"
log "挂载成功，关键信息："
sudo sed 's/^/    /' "$WORK/mnt/usr/lib/os-release" 2>/dev/null || sudo cat "$WORK/mnt/etc/os-release" | sed 's/^/    /'
sudo cp -f "$WORK/mnt/usr/lib/os-release" "$OUT/frame-os-release" 2>/dev/null || true
for p in usr/lib/modules etc/pacman.conf etc/pacman.d/mirrorlist usr/lib/libvulkan_freedreno.so usr/bin/gamescope sbin/init usr/share/wayland-sessions; do
  if sudo test -e "$WORK/mnt/$p"; then echo "    [ OK ] /$p"; else echo "    [ -- ] /$p"; fi
done
sudo umount "$WORK/mnt"
log "底包就绪: $OUT/rootfs.raw"