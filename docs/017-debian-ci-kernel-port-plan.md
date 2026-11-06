# Debian 6.x CI 方案：内核移植、驱动、rootfs 与发布（2026-11-06）

## 目标（用户定义）

- 引导/刷机方式沿用社区方案：U 盘 FAT32 → `bootargs.bin`（CRC32 env）→ hiboot `fatload usb` + `mmc write` / `mmc write.ext4sp` → 写 p2/p6/p9 → `reset`。p1 不写。
- 内核用 **Linux 6.x 主线**（`third_party/linux-hi3798mv100`，6.3-rc5 + loonpn 移植）。
- 用户空间用 **Debian bookworm armhf rootfs**，预装软件，默认开 SSH，网络 DHCP。
- 驱动尽量移植配置好，文件系统用 6.x 里支持最全的一批。
- **WiFi**：RTL8188FU USB（0bda:f179），不插网线也能用（有线口留作它用）。
- **HDMI 显示**：社区 4.4 内核能输出 1080P60 到 HDMI，说明 hiboot 已配好 HDMI/VO + framebuffer，我们也要做到。
- **温度**：原厂 3.10 有 Tsensor，要移植进 6.x 并暴露到标准 thermal 框架。
- 两个 USB 口 → 当 Linux 小主机用，键盘/鼠标/存储要能工作。
- **打包/构建一律走 GitHub Actions CI 发 release，本地只做轻量校验**（用户明确要求）。

## 调研结论（见 docs/016 与本机 SSH 实测）

| 项 | 社区 Ubuntu 20.04 / 4.4.35 | 原厂 Android / 3.10.0_s40 | 主线 6.3-rc5 移植树 |
|---|---|---|---|
| WiFi | `rtl8188fu` vendor 驱动已加载，能扫描 AP | — | `rtl8xxxu` 里已有 `0xf179 → rtl8188fu_fops`，配置 `CONFIG_RTL8XXXU` 即可 |
| HDMI | `/dev/fb0`，1080P60 YCbCr444，hiboot 留 framebuffer | — | `simplefb.c` 现成，缺 DTS 节点 |
| 温度 | `/proc/hisi/msp/chip_temp` = 63°C；`pm_temp` 阈值 | `Tsensor: temperature = %d degree` | `hisilicon,hi3798mv100-tsensor` 驱动（我们新增） |
| 文件系统 | ext4 | ext4 | ext4/f2fs/squashfs/overlay 已内置，其余需打开 |

### 温度寄存器（从 SDK 4.4 `hi3798cvx-thermal.c` 挖出）

```
PMC base 0xF8A23000
writel(0x6005, base+0x28); mdelay(16);
读 base+0x30..+0x3c 四个 32 位寄存器，各取高低 16 位中 10 bit，共 8 个样本求平均。
temp_C = ((avg - 125) * 165 / 806) - 40
```
SDK 的 `hisi_thermal.c` 是 hi6220/hi3660 的另一套寄存器，不能直接用，所以写一个
独立的小 platform 驱动注册 `thermal_zone_device` → `/sys/class/thermal/thermal_zone0/temp`。

## 落地内容

### 内核补丁（`patches/kernel/`）

- `0001-ec6108v9c-dts-simplefb-tsensor.patch`：在板级 DTS 里加
  `__FB_BLOCK__` 占位、`#define EC6108_FB_BASE/STATUS`、`tsensor@f8a23000` 节点。
- `0002-thermal-kconfig-makefile.patch`：`CONFIG_HI3798MV100_TSENSOR` + Makefile 条目。
- `hi3798mv100_tsensor.c`：新驱动（6.x thermal API，`thermal->devdata`、
  `thermal_zone_device_register`）。
- `simple-framebuffer.dtsi`：simplefb 节点片段，由 `scripts/apply-fb-dts.py` 在
  `FB_BASE` 非空时插入（1920x1080 ARGB8888，8 MiB）。`FB_BASE` 为空则整块删掉，
  避免用猜错的地址预留内存把系统搞坏。**这是唯一还没在硬件上确认的参数**，
  需要串口日志或读 VO 寄存器确认 hiboot 留的 framebuffer 物理地址。
- `configs/kernel/ec6108v9c.config`：配置片段，`scripts/build-kernel.sh` 逐行合并：
  - WiFi：`RTL8XXXU=y` + `CFG80211/MAC80211` 内置，`firmware-realtek` 提供
    `/lib/firmware/rtlwifi/rtl8188fufw.bin`。
  - HDMI：`FB_SIMPLE` + `FRAMEBUFFER_CONSOLE` + `VT` + 字体。
  - Thermal：`THERMAL_OF` + `HI3798MV100_TSENSOR=y` + governor。
  - USB/输入：EHCI/OHCI/XHCI、`USB_HID`、`INPUT_EVDEV`、`SCSI/BLK_DEV_SD`。
  - 文件系统：ext4/f2fs/btrfs/xfs/squashfs/overlay/exfat/ntfs3/fuse/nfs/cifs/tmpfs。
  - 网络：`IP_PNP_DHCP`、bridge/tun、IPv6、netfilter。

### rootfs（`scripts/build-rootfs.sh`）

- debootstrap bookworm armhf，`--components=main,contrib,non-free,non-free-firmware`。
- 预装：openssh-server（`PermitRootLogin yes`、`ssh-keygen -A`）、busybox telnetd
  (`telnetd.service` 开机自启，端口 23)、`ifupdown` + `isc-dhcp-client`（eth0 与
  `wlx8421f1edf583` 都 DHCP）、`wpasupplicant` + `wireless-tools` + `wireless-regdb`
  + `firmware-realtek`，`lm-sensors`、`fbset`、`kbd`、`console-setup`，
  以及一整套 CLI 工具（iproute2/iputils/ethtool/tcpdump/strace/lsof/htop/tmux/minicom…）。
- 串口 getty ttyAMA0 115200；`resize-rootfs.service` 首次开机把 p9 扩到整块 eMMC。
- 设备端小工具：`ec6108-wifi <SSID> <密码>` 写 wpa_supplicant.conf 并 ifup；
  `ec6108-temp` 打印温度。
- root 密码 `ec6108v9c`，`ec6108-wifi` 提示首次登录改密码。

### 打包（`scripts/make-community-flash-package.sh`）

社区同款目录结构：顶层 `bootargs.bin`（CRC32 env，`bootcmd` 依次写 p6/p9/p2 后 reset），
`mv100/hi_kernel.bin`（uImage，LBA 0x7000）、`mv100/bootargs.bin`（写 p2 的 env，
`root=/dev/mmcblk0p9` + 社区 9 分区 blkdevparts）、`mv100/debian-root.ext4`
（Android sparse，LBA 0x131000）。p1/p3/p4/p5/p7/p8 都不写。去掉两级 OpenWrt 接力。

### CI（`.github/workflows/build-release.yml`）

步骤：checkout → 装依赖（含 device-tree-compiler）→ 初始化内核子模块 →
`build-kernel.sh`（打补丁、合并 config、编译 uImage+DTB+modules）→ `build-rootfs.sh`
→ `make-community-flash-package.sh` → 参考资料存档（可选）→ 校验和 → release。
`workflow_dispatch` 输入 `fb_base`（十六进制 framebuffer 地址）与 `archive_refs`。

## 待确认（不阻塞 CI，但阻塞 HDMI 显示真正点亮）

1. hiboot 留的 framebuffer 物理地址、像素格式/stride。拿到后把 `fb_base` 填进
   `workflow_dispatch` 触发一次构建即可启用 simplefb + fbcon。
2. `rtl8xxxu` 在 8188FU 上的实际稳定性需真机验证；不行就退回社区的
   `rtl8188fu.ko`（vendor 驱动，4.4 源码，需针对 6.x 改 API）。
3. 主线 6.x 的 `hisi-femac` 网口、`dw-mmc` eMMC 已在 defconfig 里（见 docs/002），
   但 HDMI 输出与 Tsensor 需要真机确认。
4. `mmz=ddr,0,0,48M` / `vmalloc=500M` 这类海思私有 cmdline 参数在 6.x 里被忽略，
   若显示驱动需要 MMZ 内存，需要重新规划 reserved-memory。

> 本地不做镜像构建；`git apply --check`、`bash -n`、DTB 编译、CRC/sparse 头检查等
> 毫秒级校验在本地完成，完整构建交给 CI。
