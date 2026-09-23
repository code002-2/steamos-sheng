#!/usr/bin/env bash
# 10-graft.sh —— 在（已铺好 Frame userspace 的）镜像 chroot 内注入 sheng 设备层
# 由 workflow 通过 chroot 调用：chroot <mount> /root/graft/10-graft.sh
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

PARTLABEL="${PARTLABEL:-linux}"
KVER_BOOT="${KVER_BOOT:-}"
export DEBIAN_FRONTEND=noninteractive

# 1) /sbin/init 必须在（内核会 exec 它；缺了会 panic: No working init found）
for c in /sbin/init /usr/sbin/init /usr/lib/systemd/systemd; do [[ -x "$c" ]] && break; done
[[ -x "${c:-}" ]] || die "找不到 init（缺 systemd-sysvcompat？）"
log "init: $c"

# 2) 卸掉 Frame 的内核（我们用 sheng 的），再装我们的包
mapfile -t kp < <(pacman -Qq 2>/dev/null | grep -E '^linux(-[a-z0-9]+)?$' || true)
if [[ "${#kp[@]}" -gt 0 ]]; then
  warn "移除 Frame 自带内核: ${kp[*]}"
  pacman -Rdd --noconfirm --color never "${kp[@]}" || warn "移除内核失败（继续）"
fi
# Frame 固件包也换掉（我们替换 linux-firmware 语义）
# 放宽到所有固件包：Frame 可能叫 steamos-firmware / linux-firmware-* / 其它
  mapfile -t fp < <(pacman -Qq 2>/dev/null | grep -Ei '(^linux-firmware|firmware)' || true)
[[ "${#fp[@]}" -gt 0 ]] && pacman -Rdd --noconfirm --color never "${fp[@]}" || true

# 0.5) 我们的包是 makepkg 产物（未签名），Frame 的 pacman.conf 若强制校验本地包签名，
#      pacman -U 会以 "signature is unknown trust" 失败 —— 先放开本地包签名要求。
if [[ -f /etc/pacman.conf ]]; then
  sed -i 's/^[[:space:]]*LocalFileSigLevel.*/LocalFileSigLevel = Optional/' /etc/pacman.conf
  grep -q '^LocalFileSigLevel' /etc/pacman.conf || sed -i '/^\[options\]/a LocalFileSigLevel = Optional' /etc/pacman.conf
  log "已确保 LocalFileSigLevel = Optional（本地包不校验签名）"
fi

shopt -s nullglob
pkgs=(/tmp/pkgs/*.pkg.tar.*)
[[ "${#pkgs[@]}" -gt 0 ]] || die "/tmp/pkgs 下没有设备包"
log "安装 sheng 设备包（${#pkgs[@]} 个）"
# 先做一次依赖体检：pacman -T 只列出"没被满足的依赖"，是排查跨发行版底包最直接的依据
log "依赖检查（pacman -T，列出未满足项）："
pacman -T "${pkgs[@]}" 2>&1 | sed 's/^/    /' || true

if ! pacman -U --noconfirm --color never "${pkgs[@]}"; then
  warn "首次安装失败，刷新数据库补依赖后重试"
  pacman -Sy --noconfirm --color never || warn "pacman -Sy 失败（Frame 的仓库可能是内部通道，无法补包）"
  if ! pacman -U --noconfirm --color never "${pkgs[@]}"; then
    # 兜底：Frame 自带的内部仓库补不上依赖时，用 --nodeps 强装（文件照常就位；
    # 缺的运行期依赖由 Frame 自身 userspace 提供），但明确告警以便人工核查。
    # 兜底：--nodeps 跳过依赖检查；--overwrite '*' 覆盖文件冲突
    # （Frame 的固件包名可能不是 linux-firmware*，我们的 firmware-xiaomi-sheng 与它文件路径重叠，
    #   pacman 会以 "exists in filesystem" 拒绝安装，而 --nodeps 并不跳过文件冲突检查）
    warn "改用 --nodeps --overwrite '*' 强装（记下上面的 pacman -T 输出与文件冲突清单！）"
    pacman -U --noconfirm --color never --nodeps --overwrite '*' "${pkgs[@]}" \
      || die "设备包安装失败（连 --nodeps --overwrite 都装不上）"
  fi
fi

# 3) 内核模块索引（无 initramfs 启动的前提）
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
[[ -n "$KVER" ]] || die "装完内核包却看不到 /usr/lib/modules/*"
log "depmod -a $KVER"
depmod -a "$KVER" || warn "depmod 失败"
[[ -f "/usr/lib/modules/$KVER/modules.dep" ]] || die "modules.dep 未生成"

# 4) sheng 的挂载布局（替换 Frame 的 A/B 槽）
log "写 /etc/fstab: PARTLABEL=$PARTLABEL"
cat > /etc/fstab <<EOF
# steamos-sheng：sheng 分区布局（首启由 growfs 扩到分区实际大小）
PARTLABEL=$PARTLABEL /      ext4  defaults,x-systemd.growfs  0 1
EOF

# 5) 基本系统配置
: > /etc/machine-id
hostname > /etc/hostname 2>/dev/null || echo "${HOSTNAME_OVERRIDE:-xiaomi-sheng}" > /etc/hostname
ln -sf /usr/share/zoneinfo/UTC /etc/localtime 2>/dev/null || true

# 6) 服务：网络与桌面会话
systemctl enable NetworkManager.service 2>/dev/null || warn "启用 NetworkManager 失败"
for p in /usr/lib/systemd/system/gamescope-session.service /usr/lib/systemd/system/steamos-session-select.service; do [[ -e "$p" ]] && log "发现 Frame 会话单元: $p"; done
command -v sddm >/dev/null 2>&1 && { systemctl enable sddm.service || warn "启用 sddm 失败"; }
systemctl set-default graphical.target 2>/dev/null || warn "设置 graphical.target 失败"

log "sheng 设备层注入完成（内核 $KVER）"