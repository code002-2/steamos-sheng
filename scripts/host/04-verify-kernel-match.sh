#!/usr/bin/env bash
# 04-verify-kernel-match.sh —— 校验 boot.img 的内核版本与 rootfs 里的模块目录一致
#
# 为什么必须有这道闸：内核只从 `/usr/lib/modules/$(uname -r)/` 找模块，且模块的 vermagic 必须与内核
# 完全一致。**上游 sm8550-mainline 同时挂着多个 release tag**（实测：tag `7.2.6` = 09-16 构建、
# 内核 `7.2.6-sm8550-00102-gef2f794ee6f0`；tag `7.2.6-mac` = 09-17 构建、内核
# `7.2.6-sm8550-00103-g42f3b40c702a`），只要内核包与 boot.img 取自不同 tag，就会「rootfs 有模块但
# 内核一个都不加载」→ 刷进去黑屏、且日志上看不出任何构建错误。这道校验把它变成构建失败。
#
# 用法: 04-verify-kernel-match.sh <boot.img> <rootfs.img>
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

BOOT="${1:?用法: 04-verify-kernel-match.sh <boot.img> <rootfs.img>}"
IMG="${2:?}"
[[ -s "$BOOT" ]] || die "boot.img 不存在: $BOOT"
[[ -s "$IMG"  ]] || die "rootfs.img 不存在: $IMG"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 1) 从 Android boot image 里抠出内核，读出它的版本串
#    头布局：magic(8) / kernel_size(u32, 偏移 8) / kernel_addr(4) / ramdisk_size(4) / …
#    内核段从页边界（mkbootimg 默认 4096）开始，且通常是 gzip 压缩的 Image
# ---------------------------------------------------------------------------
magic="$(head -c 8 "$BOOT")"
[[ "$magic" == "ANDROID!" ]] || die "$BOOT 不是 Android boot image（magic='$magic'）"
KSIZE="$(od -An -tu4 -j8 -N4 "$BOOT" | tr -d ' ')"
[[ "$KSIZE" -gt 0 ]] || die "从 boot.img 头里读不到 kernel_size"
dd if="$BOOT" of="$TMP/k.bin" bs=4096 skip=1 count=$(( (KSIZE + 4095) / 4096 )) status=none \
  || die "抠内核段失败"
# dd 按 4096 页取整，尾部会多出零填充；不截掉的话 gunzip 会报 "trailing garbage ignored" 并以 2 退出
truncate -s "$KSIZE" "$TMP/k.bin"
sig="$(head -c2 "$TMP/k.bin" | od -An -tx1 | tr -d ' \n')"
case "$sig" in
  1f8b) log "内核段是 gzip，解压后读版本串"
        gunzip -c "$TMP/k.bin" > "$TMP/k.raw" 2>/dev/null || true
        [[ -s "$TMP/k.raw" ]] || die "gunzip 内核失败";;
  0422) die "内核段是 lz4 压缩，本脚本暂不解析（先看 boot.img 是否被换成新格式）";;
  *)    log "内核段未压缩，直接读"; cp "$TMP/k.bin" "$TMP/k.raw";;
esac
# 内核里字符串是 NUL 分隔的，必须先按 NUL 切成行再匹配，否则 `[^ ]+` 会跨过 NUL 抓到垃圾串
# （实测第一版抓到的是 "autofs_kill_sbshutting"）
# 2>/dev/null：grep -m1 命中就退出会让 tr 拿到 SIGPIPE 并打印 "write error: Broken pipe"（纯噪声）
BOOT_VER="$(tr '\0' '\n' < "$TMP/k.raw" 2>/dev/null | grep -m1 -E '^Linux version [0-9]' | awk '{print $3}' || true)"
[[ -n "$BOOT_VER" ]] || die "没能在 boot.img 的内核里读到 'Linux version …'"
# vermagic 里也带着版本串，顺手打出来（模块加载看的就是它）
VM="$(tr '\0' '\n' < "$TMP/k.raw" 2>/dev/null | grep -m1 -E '^[0-9][^ ]* SMP (PREEMPT|preempt)' || true)"
log "boot.img 内核版本: $BOOT_VER"
[[ -n "$VM" ]] && log "boot.img vermagic: $VM"
[[ -n "$VM" && "${VM%% *}" != "$BOOT_VER" ]] && warn "vermagic 首字段（${VM%% *}）与版本串不一致，以 vermagic 为准更稳"

# ---------------------------------------------------------------------------
# 2) 读 rootfs.img 里的模块目录名（用 debugfs 直接读，不需要挂载/root）
# ---------------------------------------------------------------------------
command -v debugfs >/dev/null || die "需要 debugfs（e2fsprogs）"
MODS="$(debugfs -R 'ls -l /usr/lib/modules' "$IMG" 2>/dev/null \
  | awk 'NF>1{print $NF}' | grep -vE '^\.{1,2}$' | grep -E '[0-9]' || true)"
[[ -n "$MODS" ]] || die "rootfs.img 的 /usr/lib/modules 下没有任何版本目录（内核包没装上？）"
log "rootfs 里的模块目录："
printf '%s\n' "$MODS" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 3) 比对：必须存在与 boot.img 内核版本完全相同的模块目录
# ---------------------------------------------------------------------------
match=0
while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  [[ "$m" == "$BOOT_VER" ]] && match=1
done <<< "$MODS"
if [[ "$match" -ne 1 ]]; then
  die "内核与模块版本不一致：boot.img 内核是 '$BOOT_VER'，rootfs 里只有 '$(printf '%s' "$MODS" | tr '\n' ' ')'
      → 内核不会加载这些模块（找的是 /usr/lib/modules/$BOOT_VER），刷进去必然黑屏。
      → 修法：让内核包与 boot.img 取自同一个 release tag（见 _packages.yml 的 kernel_release）。"
fi
log "版本一致 ✓（$BOOT_VER）"

# depmod 产物也要在，否则即使目录名对也加载不了
if debugfs -R "stat /usr/lib/modules/$BOOT_VER/modules.dep" "$IMG" >/dev/null 2>&1; then
  log "depmod 产物存在 ✓ (/usr/lib/modules/$BOOT_VER/modules.dep)"
else
  warn "缺少 /usr/lib/modules/$BOOT_VER/modules.dep —— depmod 可能没跑，模块仍不会加载"
fi
log "校验通过：boot.img 与 rootfs 内核一致"
