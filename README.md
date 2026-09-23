# steamos-sheng

用 **Steam Frame 官方镜像**（Valve 的 Holo Core / SteamOS aarch64）作为底包，注入 sheng 的内核与设备层，
构建可 `fastboot` 刷入**小米平板 6S Pro（sheng / SM8550）**的 `rootfs.img` + `boot.img`。
构建逻辑与目录结构参照 [debian-sheng](https://github.com/ianchb/debian-sheng)。

## 底包（公开可直连）

```
https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2
  → steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2（3.79 GiB）
```

实测形态：bz2 里是 **7 GB GPT 整盘镜像**（`esp` / `efi-A.fat` / **`rootfs-A.img`(5G)** / `var-A` / `home`）；
`rootfs-A.img` 前 5 MiB 是保留区，**之后是 zstd 压缩流**（不是裸 ext4，7-Zip 解不动，必须 zstd 本体）。

## 与 Frame 的差异（必须改的部分）

| Frame | sheng（本项目） |
|---|---|
| GPT + ESP + UEFI/systemd-boot + A/B 槽 | Android boot/dtbo 分区链：`fastboot flash boot_b` + `linux`/`userdata` 分区 |
| Frame 内核 / DTB | `linux-xiaomi-sheng`（7.2.6 + `sm8550.config`）+ debian-sheng 的 `mkbootimg` |
| Frame 固件 | `firmware-xiaomi-sheng` |
| Frame 设备服务 | `alsa-xiaomi-sheng`(UCM2) / `sheng-sensors` / `sheng-devauth` / `libssc` / `iio-sensor-proxy-sheng` / 6 个 `xiaomi-*` |
| 分区挂载布局 | `PARTLABEL=<label> / ext4 defaults,x-systemd.growfs 0 1` |

Frame 的 **userspace 全部保留**（图形栈、`libvulkan_freedreno`、gamescope、Steam 运行时、会话与配置）。

⚠️ **不要把 Frame 的整盘镜像刷进 sheng**（引导链/分区表完全不同）。