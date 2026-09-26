# steamos-sheng

以 **Steam Frame 官方恢复镜像**（SteamOS holo，aarch64）为底包的 SteamOS for sheng，产出可刷入的 `rootfs.img` + `boot.img`。

## 参数说明

`.github/workflows/rootfs.yml`（workflow_dispatch）：

| 输入 | 默认 | 说明 |
|---|---|---|
| `frame_image_url` | `steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2` | 底包地址（Valve 公开直连；仓库里已发布解好的资产时优先用资产） |
| `boot_mode` | `dual (linux)` | `dual (linux)` → fstab `PARTLABEL=linux`；`single (userdata)` → `PARTLABEL=userdata` |
| `rootfs_size` | `14G` | 初始大小下限；脚本按底包实际用量自动放大 |
| `shrink_image` | `true` | 收尾 `e2fsck -fy` + `resize2fs -M` + `truncate` |
| `kernel_release` | `7.2.6` | 上游 `ianchb/sm8550-mainline` release，boot 镜像与内核包同源 |
| `upload_artifacts` | `true` | 上传 `steamos-sheng-rootfs-<label>` / `steamos-sheng-boot-<label>`（关掉只做构建校验） |
| `wifi_ssid` / `wifi_password` | 空 | 开机自动连接的 WiFi（凭据只作为构建输入，不写进仓库；留空则用 DHCP 但不预配 WiFi） |
| `ssh_pubkey` | 内置调试公钥 | 写入 root 的 `authorized_keys`（公钥登录不经过 PAM 密码链，是最稳的入口） |
| `root_password` | `123456` | root 密码（用于 SSH；留空则不设置） |

刷入方式：

```sh
fastboot flash userdata rootfs.img     # single (userdata) 模式
fastboot flash boot_b  boot.img
```

镜像内已固化（都是实机验证过的）：`rootwait` 写入 boot.img、SDDM 直连 Plasma（自动登录 `steamos`）、`xiaomi-sheng-thp` 触屏守护进程 + `/etc/modules-load.d/uinput.conf`、`sheng-devauth` / `adsprpcd-sensorspd` 启用；其余设备服务（iio-sensor-proxy、qteesupplicant、键盘 helper、charger / pen）由各自 udev 规则按需触发；指纹栈（自编 `libfprint` 1.94.10 + `fprintd` 1.94.5）；`fastfetch`。

> 调试开关（`debug_console` 文本控制台模式、`patch_cmdline` cmdline 注入、boot 变体 A/B 对照）在桌面链路稳定后已全部移除；镜像里不再有任何免密 root 入口。

底包已预先解包并发成 release 资产 `frame-base-20260922`（`rootfs.partNN.zst` + `SHA256SUMS`），构建时直接下载拼回；换底包版本时跑一次 `.github/workflows/publish-base.yml` 即可。底包结构：GPT `esp(256M) / efi-A(64M) / rootfs-A(5G btrfs) / var-A(256M) / home(100M)`。

产出镜像：ext4、标签 `rootfs`、固定 UUID `ee8d3593-59b1-480e-a3b6-4fefb17ee7d8`（与上游内核 cmdline 对应）；fstab 用 `PARTLABEL` + `x-systemd.growfs`，首启自动扩到分区大小；无 initramfs（内核直接挂根）。

## 许可与第三方组件

- SteamOS / Steam Frame userspace：Valve Corporation（仅作本移植底包，镜像内组件版权归 Valve）
- Arch Linux ARM 设备包与基础软件包：Arch Linux ARM
- 内核 `7.2.6-sm8550` 及 `boot.img`：上游 `ianchb/sm8550-mainline`
- 设备包构建复用 `code002-2/archlinux-sheng` 的 `_packages.yml`
- 本项目自身脚本：见 `LICENSE`

## 致谢

- [ianchb/debian-sheng](https://github.com/ianchb/debian-sheng)：本仓库脚本结构与构建流程参照其实现
- [ianchb/sm8550-mainline](https://github.com/ianchb/sm8550-mainline)：sheng 内核与 boot 镜像
- Arch Linux ARM：aarch64 基础包与设备包构建环境
