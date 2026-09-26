#!/usr/bin/env bash
# 00b-publish-base.sh —— 把解好的 Steam Frame rootfs 分区发布成 release 资产
#
# 为什么要发：底包是 3.8 GB 的 bz2，展开成 7.1 GB 的 GPT，每次构建都要「下载 + 解 bz2 + 解析 GPT +
# 再解一遍」≈ 10 分钟，而且 runner 盘很紧。解好的 rootfs 分区只有 5 GiB，切块压缩后约 3 GB，
# 后续构建直接下载 → 拼回去即可，省掉两次 bz2 解压。
#
# 资产命名：rootfs.partNN.zst（每块 1900 MiB，各自独立 zstd 帧，可逐块解压后顺序追加）
# 依赖：GH_TOKEN（contents: write）、gh、curl、bzip2、zstd、python3
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

TAG="${TAG:-frame-base-20260922}"
BASE_REPO="${BASE_REPO:-code002-2/steamos-sheng}"
WORK="${WORK:-/mnt/frame-work}"
OUT="${OUT:-$WORK/out}"
CHUNK="${CHUNK:-1900M}"
FRAME="$OUT/rootfs.frame"
PUB="$WORK/base"
[[ -n "${GH_TOKEN:-}" ]] || die "需要 GH_TOKEN（发布资产要 contents: write）"
mkdir -p "$PUB"

# 1) 先产出 rootfs.frame（复用取包脚本；强制走 bz2 那条路，避免「从自己的资产下载自己」）
if [[ ! -s "$FRAME" ]]; then
  log "第 1 步：从官方 bz2 解出 rootfs 分区（FRAME_BASE_SKIP=1 强制走原始路径）"
  sudo env FRAME_BASE_SKIP=1 FRAME_IMAGE_URL="${FRAME_IMAGE_URL:-}" WORK="$WORK" OUT="$OUT" \
    bash "$HERE/00-fetch-frame-rootfs.sh"
fi
SIZE="$(stat -c %s "$FRAME")"
log "rootfs.frame: $SIZE 字节"
[[ "$SIZE" -gt 1073741824 ]] || die "rootfs.frame 太小，不对劲"

# 2) 切块（每块独立 zstd 帧；CI 逐块解压后顺序追加，等价于整块解压）
log "第 2 步：按 $CHUNK 切块 + zstd 压缩"
rm -f "$PUB"/rootfs.part*.zst
split -b "$CHUNK" -d -a 2 "$FRAME" "$PUB/rootfs.part"
: > "$PUB/SHA256SUMS"
for raw in "$PUB"/rootfs.part[0-9][0-9]; do
  [[ -e "$raw" ]] || continue
  zstd -3 -T0 -q -f "$raw" -o "$raw.zst" || die "zstd 压缩失败: $raw"
  ( cd "$PUB" && sha256sum "$(basename "$raw").zst" >> SHA256SUMS )
  rm -f "$raw"
  log "  $(basename "$raw").zst → $(du -h "$raw.zst" | cut -f1)"
done
sha256sum "$FRAME" | awk '{print $1"  rootfs.frame"}' >> "$PUB/SHA256SUMS"
log "原始镜像 sha256: $(sha256sum "$FRAME" | cut -d' ' -f1)"
log "分块总计: $(du -sh "$PUB" | cut -f1)"
df -h "$WORK" | tail -1 | sed "s/^/    磁盘: /"

# 3) 建/取 release 并上传（--clobber 便于重发）
log "第 3 步：发布到 $BASE_REPO 的 release '$TAG'"
if ! gh release view "$TAG" --repo "$BASE_REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$BASE_REPO" \
    --title "Steam Frame base (rootfs-A) $TAG" \
    --notes "Steam Frame 官方 OOBE 恢复镜像里解出的 rootfs 分区（btrfs，label=rootfs-A，5 GiB）。

来源（Valve 公开直连）：https://steamdeck-images.steamos.cloud/recovery/steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2
分区表：esp(256M) / efi-A(64M) / **rootfs-A(5G)** / var-A(256M) / home(100M)

资产为 rootfs.partNN.zst（每块 1900 MiB，独立 zstd 帧，逐块解压后顺序追加即为完整分区镜像），
SHA256SUMS 含每块与整镜像的校验和。仅供本项目构建底包使用。" \
    || die "创建 release 失败"
fi
gh release upload "$TAG" "$PUB"/rootfs.part*.zst "$PUB"/SHA256SUMS --repo "$BASE_REPO" --clobber \
  || die "上传资产失败"
log "已上传资产："
gh release view "$TAG" --repo "$BASE_REPO" --json assets \
  --jq '.assets[] | "  \(.name)  \(.size) 字节"' || true
