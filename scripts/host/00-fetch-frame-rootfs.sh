#!/usr/bin/env bash
# 00-fetch-frame-rootfs.sh —— 取 Steam Frame 官方镜像并解出 rootfs 分区
#
# 底包形态（实测 steamframe-oobe-repair-20260922.5153644-0.3.0）：
#   .img.bz2  →  7.5 GB 的 **GPT 整盘镜像**，5 个分区：
#       0.esp.img(256M) / 1.efi-A.fat(64M) / 2.rootfs-A.img(5G) / 3.var-A.img(256M) / 4.home.img(100M)
#
#   ⚠️ 2.rootfs-A.img 是 **btrfs 文件系统镜像**（label = rootfs-A，超块 `_BHRfS_M` 在偏移 65536），
#      **不是**「ext4 + zstd 载荷」。曾经误判过：该分区 5 MiB+4096 处恰好有一个 zstd 帧
#      （那只是 btrfs 里某个文件的 zstd 压缩 extent，解出来仅 8192 字节），照那个偏移切片解压
#      只会得到一堆垃圾。正确做法就是**按文件系统直接挂载**。
#
#   ⚠️ 磁盘：bz2(4 GB) + 整盘镜像(7.5 GB) 同时存在就是 11.6 GB，runner 的盘不够。
#      所以这里走「流式两遍」：第 1 遍只取前 4 MB 解析 GPT 分区表，第 2 遍
#      curl | bunzip2 | dd 精确切出 rootfs 分区 —— 全程只落盘 5 GB。
#
# 产出（$OUT 下）：
#   rootfs.frame        rootfs 分区原样镜像（约 5 GB，可 loop 挂载）
#   frame-src-root      根子树相对路径（`.` 或 `@` / `root` 之类）
#   frame-src-extra     需并入的子卷，每行「相对路径<TAB>目标路径」
#   frame-os-release    Frame 的 os-release 副本（用于记录底包版本）
#
# 环境变量：
#   FRAME_IMAGE_URL  默认官方 steamframe-repair-latest.img.bz2（公开可直连）
#   WORK             工作目录（默认 /mnt/frame-work，需 ≥ 8 GB 空闲）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

FRAME_IMAGE_URL="${FRAME_IMAGE_URL:-https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2}"
WORK="${WORK:-/mnt/frame-work}"
OUT="${OUT:-$WORK/out}"
MNT="$WORK/frame-src"
HEAD="$WORK/frame-head.bin"
IMG="$WORK/frame.img"          # 整盘 GPT 镜像（只在原始 bz2 路径下用到，切完分区立刻删）
FRAME="$OUT/rootfs.frame"
sudo mkdir -p "$WORK" "$OUT"

# 候选地址：`steamframe-repair-latest` 别名在 CDN 上会返回 BlobNotFound（CI 实测），
# 因此把明确的版本化文件名作为兜底；两者都试。函数把 bz2 流直接吐给 stdout。
CANDIDATES=(
  "$FRAME_IMAGE_URL"
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2"
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2"
)
DLOAD() {
  local u rc
  for u in "${CANDIDATES[@]}"; do
    [[ -n "$u" ]] || continue
    log "尝试下载: $u" >&2
    # ⚠️ 必须写成 `|| rc=$?`：直接 `curl ...; rc=$?` 时，set -e 会在 curl 非 0 的瞬间就把
    #    这个子 shell 干掉，下面的 23 判断根本执行不到（实跑踩过：报「下载失败（curl 23）」）。
    rc=0
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o - "$u" || rc=$?
    # ⚠️ curl 23 = "Failure writing output to destination"：下游 head/dd 读够字节就关管子，
    #    curl 写不进去是**预期**行为，必须当成功。曾把它当失败 → DLOAD 从头重下第二个候选，
    #    dd 把「重启的流」接着写进同一个文件 → 只产出 25 MB 垃圾（实跑踩过）。
    if [[ "$rc" -eq 0 || "$rc" -eq 23 ]]; then return 0; fi
    warn "该地址不可用（curl $rc），换下一个" >&2
  done
  return 1
}

# ---------------------------------------------------------------------------
# 0) 资产优先：若本项目已把「解好的 rootfs 分区」发布成 release 资产（见 00b-publish-base.sh），
#    直接下载拼回即可 —— 省掉每次「下 3.8 GB bz2 + 解两遍 bz2」，也不需要 GPT 解析。
#    想强制走原始 bz2 路径：FRAME_BASE_SKIP=1（发布脚本自己就是这么调用的）
# ---------------------------------------------------------------------------
BASE_TAG="${FRAME_BASE_TAG:-frame-base-20260922}"
BASE_REPO="${FRAME_BASE_REPO:-code002-2/steamos-sheng}"
declare -a ASSETS=()
if [[ "${FRAME_BASE_SKIP:-0}" != "1" ]] && [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null; then
  mapfile -t ASSETS < <(gh release view "$BASE_TAG" --repo "$BASE_REPO" --json assets \
    --jq '.assets[].name' 2>/dev/null | grep -E '^rootfs\.part[0-9]+\.zst$' | sort || true)
fi

if [[ "${#ASSETS[@]}" -gt 0 ]]; then
  log "发现已发布的底包资产 $BASE_REPO@$BASE_TAG：${ASSETS[*]}"
  mkdir -p "$WORK/base"
  : > "$FRAME"
  for a in "${ASSETS[@]}"; do
    log "  下载并解压 $a"
    gh release download "$BASE_TAG" --repo "$BASE_REPO" --pattern "$a" --dir "$WORK/base" --clobber \
      || die "下载资产 $a 失败"
    zstd -dc "$WORK/base/$a" >> "$FRAME" || die "解压资产 $a 失败（文件损坏？）"
    rm -f "$WORK/base/$a"   # 逐块删，保证磁盘峰值只有「已解出的部分 + 当前块」
    log "    累计 $(du -h "$FRAME" | cut -f1)"
  done
  GOT="$(stat -c %s "$FRAME")"
  if [[ "$GOT" -lt 1073741824 ]]; then
    die "拼回的 rootfs 只有 $GOT 字节，资产不完整（删掉 release 里的资产重发一次）"
  fi
  log "资产路径完成：$GOT 字节"
  df -h "$WORK" | tail -1 | sed "s/^/    磁盘: /"
else
  log "没有可用的底包资产，走原始路径（官方 bz2 → 整盘 GPT → 切分区）"

# ---------------------------------------------------------------------------
# 1) 流式下载并解压整盘镜像（curl | bunzip2 > 文件，不落 bz2）
#    这里 bunzip2 是「读到流尾」的正常消费，不存在下游提前关管的问题 —— 之前试图
#    用 `curl | bunzip2 | dd skip=X count=Y` 一遍切出来，dd 写够就退出导致上游 EPIPE，
#    实测只产出 25 MB（管道早关的坑），改成「文件→文件」两段式，行为完全确定。
#    磁盘：整盘 7.1 GB（此时无 bz2）→ 切出 5 GB 分区（峰值 12.1 GB）→ 删掉整盘。
# ---------------------------------------------------------------------------
log "下载并解压 → 整盘 GPT 镜像（约 7.1 GB）"
rm -f "$IMG"
set +o pipefail
DLOAD | bunzip2 -c > "$IMG"
rc_dload="${PIPESTATUS[0]}"
set -o pipefail
[[ "$rc_dload" -eq 0 ]] || die "下载失败（curl $rc_dload）"
GOT_IMG="$(stat -c %s "$IMG" 2>/dev/null || echo 0)"
[[ "$GOT_IMG" -gt 6442450944 ]] || die "整盘镜像只有 $GOT_IMG 字节（期望 >6 GiB），下载/解压被截断"
log "整盘镜像: $(du -h "$IMG" | cut -f1)"
df -h "$WORK" | tail -1 | sed "s/^/    磁盘: /"

# ---------------------------------------------------------------------------
# 2) 解析分区表，按**名字**定位 rootfs 分区（真实底包里 p2 是 64 MiB 的 efi-A，
#    硬编码分区号会切错 —— 实测踩过），然后文件→文件精确切出
# ---------------------------------------------------------------------------
python3 "$HERE/parse-gpt.py" "$IMG" rootfs 2>&1 | sed 's/^/[gpt] /' >&2 || true
read -r ROOTFS_OFF ROOTFS_LEN ROOTFS_NAME < <(python3 "$HERE/parse-gpt.py" "$IMG" rootfs) \
  || die "解析 GPT 分区表失败（底包结构可能变了）"
[[ "$ROOTFS_OFF" =~ ^[0-9]+$ && "$ROOTFS_LEN" =~ ^[0-9]+$ ]] || die "解析出的偏移/长度非法: '$ROOTFS_OFF' '$ROOTFS_LEN'"
[[ "$ROOTFS_LEN" -gt 1073741824 ]] || die "rootfs 分区只有 $ROOTFS_LEN 字节，明显不对"
[[ $(( ROOTFS_OFF + ROOTFS_LEN )) -le "$GOT_IMG" ]] || die "rootfs 分区越界（偏移 $ROOTFS_OFF + 长度 $ROOTFS_LEN > 镜像 $GOT_IMG）"
log "rootfs 分区: '$ROOTFS_NAME' 偏移 $ROOTFS_OFF 长度 $((ROOTFS_LEN / 1024 / 1024)) MiB"

log "切出 rootfs 分区 → $FRAME（文件→文件 dd，无管道）"
rm -f "$FRAME"
dd if="$IMG" of="$FRAME" bs=4M iflag=skip_bytes,count_bytes \
  skip="$ROOTFS_OFF" count="$ROOTFS_LEN" status=none || die "dd 切分区失败"
GOT="$(stat -c %s "$FRAME" 2>/dev/null || echo 0)"
[[ "$GOT" -eq "$ROOTFS_LEN" ]] || die "切分区失败：期望 $ROOTFS_LEN 字节，实际 $GOT 字节"
rm -f "$IMG" "$HEAD" && log "已删除整盘镜像，释放空间"
log "已切出: $(du -h "$FRAME" | cut -f1)"
df -h "$WORK" | tail -1 | sed "s/^/    磁盘: /"
fi

# ---------------------------------------------------------------------------
# 4) 识别文件系统类型（btrfs / ext4）——决定挂载参数
# ---------------------------------------------------------------------------
sudo modprobe btrfs 2>/dev/null || warn "modprobe btrfs 失败（若底包是 btrfs 会挂不上）"
FSTYPE="$(sudo blkid -o value -s TYPE "$FRAME" 2>/dev/null || true)"
[[ -n "$FSTYPE" ]] || FSTYPE="auto"
LABEL="$(sudo blkid -o value -s LABEL "$FRAME" 2>/dev/null || true)"
log "rootfs.frame: fstype=$FSTYPE label=${LABEL:-无}"
[[ "$FSTYPE" == "auto" ]] && die "切出来的分区认不出文件系统（偏移算错了？）"

# ---------------------------------------------------------------------------
# 5) 挂载：btrfs 用 subvolid=5 挂顶层（能看到所有子卷）
# ---------------------------------------------------------------------------
sudo mkdir -p "$MNT"
sudo umount "$MNT" 2>/dev/null || true
MOUNTED=0
if [[ "$FSTYPE" == "btrfs" ]]; then
  sudo mount -o loop,ro,subvolid=5 "$FRAME" "$MNT" && MOUNTED=1 || true
fi
if [[ "$MOUNTED" -eq 0 ]]; then
  log "改用自动识别挂载（-o loop,ro）"
  sudo mount -o loop,ro "$FRAME" "$MNT" || die "挂载失败：既不是可识别的 btrfs，也不是 ext4"
fi
trap 'sudo umount "$MNT" 2>/dev/null || true' EXIT
log "已挂载，顶层内容："; sudo ls -A "$MNT" | head -20 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 6) 找根子树：先看挂载点本身，再看一层/两层子目录里谁含 usr/lib/os-release
# ---------------------------------------------------------------------------
has_root() { sudo test -e "$1/usr/lib/os-release" || sudo test -e "$1/etc/os-release"; }
SRC_ROOT=""
if has_root "$MNT"; then
  SRC_ROOT="."
else
  while IFS= read -r d; do
    rel="${d#"$MNT"/}"
    if has_root "$d"; then SRC_ROOT="$rel"; break; fi
    while IFS= read -r d2; do
      rel2="${d2#"$MNT"/}"
      if has_root "$d2"; then SRC_ROOT="$rel2"; break 2; fi
    done < <(sudo find "$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  done < <(sudo find "$MNT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
fi
[[ -n "$SRC_ROOT" ]] || die "挂载成功但找不到根子树（没有任何目录含 usr/lib/os-release），底包结构可能变了"
log "根子树: $SRC_ROOT"

# ---------------------------------------------------------------------------
# 7) 平级子卷 → 目标路径映射（SteamOS 的 btrfs 常把 /var /home 放独立子卷）
#    不并进来会出现「/var 空空如也」→ systemd 起不来、pacman 数据库也没了
# ---------------------------------------------------------------------------
EXTRA_FILE="$OUT/frame-src-extra"
: > "$EXTRA_FILE"
merge_map() {
  local src="$1" dst="$2"
  [[ -d "$MNT/$src" ]] || return 0
  printf '%s\t%s\n' "$src" "$dst" >> "$EXTRA_FILE"
  log "并入子卷: $src → /$dst"
}
for pair in '@var:var' 'var:var' '@var-log:var/log' 'var-log:var/log' '@home:home' 'home:home' \
            '@usr:usr' 'usr:usr' '@opt:opt' 'opt:opt' '@srv:srv' 'srv:srv' '@root:root' 'root:root'; do
  s="${pair%%:*}"; d="${pair##*:}"
  [[ "$s" == "$SRC_ROOT" ]] && continue
  [[ "$d" == "root" && "$SRC_ROOT" != "." ]] && continue
  merge_map "$s" "$d"
done
[[ -s "$EXTRA_FILE" ]] || log "没有需要额外并入的子卷"

# ---------------------------------------------------------------------------
# 8) 关键信息核对 + 落盘 os-release
# ---------------------------------------------------------------------------
if [[ "$FSTYPE" == "btrfs" ]] && command -v btrfs >/dev/null; then
  log "btrfs 子卷清单："; sudo btrfs subvolume list "$MNT" 2>/dev/null | sed 's/^/    /' || true
fi
if sudo test -e "$MNT/$SRC_ROOT/usr/lib/os-release"; then
  sudo sed 's/^/    /' "$MNT/$SRC_ROOT/usr/lib/os-release"
  sudo cp -f "$MNT/$SRC_ROOT/usr/lib/os-release" "$OUT/frame-os-release"
elif sudo test -e "$MNT/$SRC_ROOT/etc/os-release"; then
  sudo sed 's/^/    /' "$MNT/$SRC_ROOT/etc/os-release"
  sudo cp -f "$MNT/$SRC_ROOT/etc/os-release" "$OUT/frame-os-release"
fi
PROBE_ROOT="$MNT/$SRC_ROOT"
log "关键路径自查（根子树内）："
for p in usr/lib/modules etc/pacman.conf etc/pacman.d/mirrorlist usr/lib/libvulkan_freedreno.so \
         usr/bin/gamescope usr/bin/steamos-session-select usr/lib/systemd/systemd sbin/init \
         usr/share/wayland-sessions usr/lib/os-release var/lib/pacman home; do
  if sudo test -e "$PROBE_ROOT/$p"; then echo "    [ OK ] /$p"; else echo "    [ -- ] /$p"; fi
done
log "根子树占用（目标镜像至少要比它大 1.5 GB）："
sudo du -sm --exclude=proc --exclude=sys --exclude=dev --exclude=run --exclude=tmp "$PROBE_ROOT" 2>/dev/null \
  | awk '{printf "    %d MiB (%.2f GiB)\n", $1, $1/1024}' || true
if [[ -s "$EXTRA_FILE" ]]; then
  while IFS=$'\t' read -r s d; do
    [[ -n "$s" ]] || continue
    sudo du -sm "$MNT/$s" 2>/dev/null | awk -v s="$s" '{printf "    子卷 %s: %d MiB\n", s, $1}' || true
  done < "$EXTRA_FILE"
fi

printf '%s\n' "$SRC_ROOT" > "$OUT/frame-src-root"
sudo umount "$MNT"; trap - EXIT
df -h "$WORK" | tail -1 | sed "s/^/    磁盘: /"
log "底包就绪: $FRAME（根子树 $SRC_ROOT，额外子卷 $(wc -l < "$EXTRA_FILE") 个）"
