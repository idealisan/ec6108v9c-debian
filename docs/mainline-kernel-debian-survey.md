# 主线内核 + Debian rootfs 路线调查

- 日期：2026-11-02
- 范围：从 Linux 主线内核 + Debian rootfs 出发做 EC6108V9C 系统的可行性调查，含社区内核仓库评估
- 配套文档：`docs/report.md`（刷机包引导与刷机机制逆向分析）

## 0. 结论速览

1. **主线内核（torvalds/linux）完全没有 Hi3798MV100 支持**。主线 ARM32 的 hisilicon DTS 只有 hi3519 / hi3620 / hip01 / hip04 / hisi-x5hd2 / sd5203；hi3798 系列（cv200/mv200）只在 arm64 分支且是 A53 64 位，与 MV100（32 位 Cortex-A7）无关。
2. **可行路线是社区移植**：`loonpn/ec6108v9c-linux-kernel`（主线 fork + 移植补丁），且有现成的 **6.14.3 预编译 uImage + modules**，可直接刷入 kernel 分区。
3. **无需 initramfs**：实测该内核把 ext4、eMMC（dw_mmc）、网口（hisi_femac）、USB host、串口 pl011 全部编进内核（built-in），rootfs 可直接挂 eMMC 上的 ext4。
4. **Debian armhf rootfs 用 debootstrap 二阶段构建**，内核 6.14 足够新，可跑 Debian 12/13；社区已有 Debian 9 / Ubuntu 20.04 成功案例。
5. 与刷机机制无缝对接：uImage → kernel 分区（LBA `0x7000`），rootfs → p9（`0x131000`），bootargs 用 `root=/dev/mmcblk0p9` + `blkdevparts`。

## 1. 主线内核支持现状

| 项目 | 事实 | 证据 |
|---|---|---|
| 主线 ARM32 hisilicon | 仅 `hi3519`、`hi3620`、`hip01`、`hip04`、`hisi-x5hd2`、`sd5203` 共 12 个文件 | torvalds/linux `arch/arm/boot/dts/hisilicon/` |
| hi3798 系列上游 | 只有 64 位的 `hi3798cv200` / `hi3798mv200`（Cortex-A53），在 arm64 目录 | 主线 `arch/arm64/boot/dts/hisilicon/`；2024 年 net-next 有 `hisi_femac` 驱动补丁支持 hi3798mv200 |
| MV100 为何进不了主线 | 依赖海思 SDK 的一整套外挂驱动（MTD/NAND/SPINOR、图形与多媒体、专有时钟/复位、定制化 SMP 启动），并非上游可维护形态 | loonpn 移植提交中导入的 SDK 驱动清单 |
| 反面经验 | 直接用 kernel.org 源码编译 uImage 会出现 CPU crash / data abort，只有 SDK 4.4 能跑起来 | GitLab 项目 `stuffs-with-hi3798mv100-board` 的作者笔记 |

结论：**“纯主线”在 MV100 上不可行**，必须叠加社区移植补丁；长期要主线化需重写/替换 SDK 驱动，短期不现实。

## 2. 社区内核仓库评估

### 2.1 loonpn/ec6108v9c-linux-kernel（推荐）

- 地址：https://github.com/loonpn/ec6108v9c-linux-kernel （fork 自 torvalds/linux，20 stars / 5 forks）
- 移植提交：`8ac5168` “Added hi3798mv100 soc based ec6108v9c support”（2023-03-27），主要改动：
  - DTS：`arch/arm/boot/dts/hi3798mv100-ec6108v9c.dts` + `hi3798mv100.dtsi`（基于 `hi3798cv200.dtsi` 适配）
  - `arch/arm/configs/hi3798mv100_defconfig`
  - `arch/arm/mach-hisi/`：`headsmp.S`、`platsmp.c`、`hotplug.c`、`hisilicon.c`（自定义 SMP 启动 `hisilicon,hi3798-smp`）
  - 时钟：`drivers/clk/hisilicon/crg-hi3798.c`（替换原 `crg-hi3798cv200.c`）
  - 海思 SDK MTD：`hisfc350`（SPI NOR/NAND）、`hinfc610`（NAND）、`hifmc100`、`spinand`/`spinor`
  - USB：`drivers/phy/hisilicon/phy-hisi-inno-usb2.c` 修改
  - `include/dt-bindings/clock/hi3798mv100-clock.h` 等

**分支情况（重要）**

| 分支/标签 | 内容 |
|---|---|
| `master` | 6.3-rc5 + 移植补丁（可用，基线较老） |
| `mainline` | 6.3-rc5 上游基线 |
| `mainline-latest` | 干净上游 **6.16.0**，**不含移植补丁** |
| 标签 `v6.2.6` / `v6.14.3` | 都指向同一个 2023 年的 merge commit（`0eb33e8`），即仓库里没有 6.14.3 的源码分支，6.14.3 只是预编译二进制发布 |

→ 若想自编译 6.14/6.16，需自行把 `8ac5168` 补丁集 rebase 到新基线；注意 **≥6.10 起 ARM DTS 迁到 `arch/arm/boot/dts/hisilicon/`**，路径需调整。

#### 预编译产物实测（v6.14.3）

| 项目 | 实测结果 |
|---|---|
| `uImage` | 6.02 MB，尾部附加 DTB（偏移 `0x600550`，18242 字节）；DTB 中 `model = "Huawei EC6108V9C"`、`compatible = "hisilicon,hi3798mv100"` |
| `modules.tar.gz` | 25.9 MB，`lib/modules/6.14.3/`，1930 个 `.ko` |
| 内置驱动（`modules.builtin`） | `ext4`、`dw_mmc` + `dw_mmc-hi3798cv200`（eMMC）、`hisi_femac` + `mdio-hisi-femac`（网口）、`ehci`/`ohci`（USB2）、`amba-pl011`（串口）、`vfat`/`nls` |
| 模块形式 | `usb-storage`、`fuse`、`loop`、无线驱动（realtek 等）及其余 1900+ |
| 结论 | **根分区所需驱动全部内置 → 不需要 initramfs/initrd** |

#### 构建方式（与 `report.md` 逆向出的引导格式完全吻合）

```
cat arch/arm/boot/zImage arch/arm/boot/dts/hi3798mv100-ec6108v9c.dtb > zImage-dtb
mkimage -A arm -O linux -T kernel -C none -a 0X2000000 -e 0X2000000 -n linux -d zImage-dtb uImage
```

即：**zImage + 尾附 DTB，raw 未压缩、加载地址 0x2000000**，正好对应 hiboot 的 `mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0`。

#### 硬件支持（板级 DTS 启用的节点）

- eMMC：`hisilicon,hi3798cv200-dw-mshc`，HS200/HS-DDR，100MHz，fifo-depth 256
- SD：`snps,dw-mshc`
- 网口：`hisi-femac-v2`，`phy-mode = "mii"`（百兆），MDIO 外挂 PHY
- USB：OHCI/EHCI ×2 组 + **XHCI（USB3）**；PHY 为 `hisilicon,hi3798cv200-usb2-phy`
- 串口：uart0（pl011 @0xf8b00000）→ console
- 红外 `hix5hd2-ir`、看门狗 sp805、timer1~4、7 组 PL061 GPIO、LED（network/ir，gpio0/gpio2/gpio5）、Mali-450 GPU
- **无 HDMI 显示驱动**（主线没有海思 hifb/vo 与解码器驱动）→ 该内核只能串口/SSH 使用，无图形与视频解码

#### defconfig 关键点

`CONFIG_ARCH_HISI=y`、`CONFIG_ARM_APPENDED_DTB=y`、`CONFIG_ARM_ATAG_DTB_COMPAT=y`（hiboot 传参可覆盖 DTB chosen）、`CONFIG_CMDLINE_PARTITION=y`（支持 `blkdevparts` 命令行分区，正是该平台所需）、`CONFIG_ARM_LPAE=y`、cgroup/namespace 全开（可跑容器）。

### 2.2 海思 SDK 路线（备选）

| 仓库/资源 | 内核 | 特点 |
|---|---|---|
| `HiSTBLinuxV100R005C00SPC060`（GitHub `zjkanjie` / Gitee 镜像） | linux-4.4.y | 官方 SDK，产出 `fastboot-burn.bin` / `bootargs.bin` / `hi_kernel.bin`，HiTool 烧录；驱动最全（HDMI、解码、遥控） |
| `lixing865/hi3798m`（Gitee） | 4.4.35 | 目标板正是 EC6108v9c，内核支持 Docker |
| `glinuz/hi3798mv100` | SDK SPC041B020 | 附 Ubuntu 16.04 rootfs 流程、`bootargs.txt`、`emmc_partitions.xml`（分区模板：uboot 1M / bootargs 1M / kernel 8M / rootfs 128M） |
| `hihopeorg/linux-hi3798mv100` | 3.10 | 网络教程引用，过旧 |

优点：驱动最全。缺点：4.4 老内核，Debian 新版兼容性与安全更新差，需 HiTool（Windows 工具）烧录。

### 2.3 生态参考

- **海纳思系统**（www.ecoo.top，开发者 teasiu）：基于 Ubuntu 20.04 的机顶盒 NAS 发行版，适配 hi3798mv1xx/2xx/3xx，有 U 盘卡刷固件 —— 正是 `report.md` 分析的刷机包生态；配套论坛 bbs.histb.com（含 WiFi 驱动安装教程）。
- `lorzzn` 博客：debootstrap 构建 Debian 9 / Ubuntu 20.04/22.04 刷入 EC6108V9C，实测 Ubuntu 20.04 最稳；刷完需 `resize2fs /dev/mmcblk0p9`（初始根分区仅约 420MB）。

## 3. Debian rootfs 路线

### 3.1 架构与版本

- **armhf**（Cortex-A7，VFPv4 + NEON，无 64 位支持）
- 内核 6.14 足够新，可跑 **Debian 12 (bookworm) / 13 (trixie) armhf**；社区实测 Ubuntu 20.04 armhf 最稳定（保守可选 Debian 11/12）

### 3.2 构建（debootstrap 二阶段 + qemu 静态）

```
sudo debootstrap --arch=armhf --variant=minbase --foreign \
  --include=locales,util-linux,apt-utils,ifupdown,systemd-sysv,iproute2,curl,wget,\
ca-certificates,openssh-server,isc-dhcp-client,vim-tiny,parted,bc \
  bookworm rootfs http://mirrors.ustc.edu.cn/debian/

cp /usr/bin/qemu-arm-static rootfs/usr/bin/
chroot rootfs /debootstrap/debootstrap --second-stage
chroot rootfs dpkg --configure -a
```

### 3.3 必须处理的配置

1. **串口 console**：`systemctl enable serial-getty@ttyAMA0` —— 主线内核 console 为 `ttyAMA0,115200`
2. **网络**：systemd-networkd 或 ifupdown 配置 DHCP（网口 `eth0`，hisi-femac）
3. **SSH**：`openssh-server`，允许 root 需设 `PermitRootLogin yes` + 设密码
4. **扩容**：刷机后根分区小，首次启动执行 `resize2fs /dev/mmcblk0p9`
5. **locale / 时区 / hosts**：`127.0.0.1 ec6108v9c`
6. **U 盘自动挂载**（若做 NAS）：udev 规则 + systemd `usb-mount@.service`，注意 systemd-udevd 需 `MountFlags=shared`
7. **内核模块**：把 `modules.tar.gz` 解到 rootfs 根目录（`/lib/modules/6.14.3/`）；内置驱动已足够启动，模块按需加载

### 3.4 可选能力

- **Docker**：内核 cgroup/namespace 已开，armhf 上用 `apt install docker.io`；**不要**用 `curl get.docker.com | sh`（会装 x86_64 专用 docker-ce）
- **WiFi**：盒载 WiFi（原厂 Hi1131 类）无主线驱动，需外挂模块（histb 论坛有教程）；USB 无线网卡更省事，但受 USB 2.0 带宽限制
- **无 HDMI 输出**：该内核下放弃图形/视频解码用途

## 4. 与刷机机制对接

| 步骤 | 做法 |
|---|---|
| 内核 | 将 uImage（6.02MB）写入 p6 kernel 分区：LBA `0x7000`（14MB 处），分区上限 20MB，容量足够 |
| rootfs | Debian 根分区（ext4）写入 p9：起始 LBA `0x131000`（610MB 处），占满剩余空间；U 盘脚本用 `mmc write.ext4sp` 写 sparse 镜像，或用 `dd` |
| bootargs | `root=/dev/mmcblk0p9 rootfstype=ext4 rootwait blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),20M(kernel),64M(busybox),512M(backup),-(ubuntu)`；内核有 `CONFIG_CMDLINE_PARTITION` 支持该命令行分区 |
| 兜底 | 也可把 `root=` 编进 DTB 的 `chosen.bootargs`（社区包就是这么做的，见 `report.md` 中 bootargs9） |
| 救援 | 保留 p7 的 recoverybox（OpenWrt）不动，改 p2 bootargs 即可来回切换主系统/救援系统 |
| CRC | 自制 `bootargs.bin` 必须重算头部小端 CRC32（算法见 `report.md` 第 6.1 节），否则 hiboot 拒绝执行 |

## 5. 推荐路线

- **路线 A（最快，建议先做）**：直接用 loonpn 的 v6.14.3 预编译 uImage + modules，配自构建的 Debian 12 armhf rootfs，按第 4 节刷入验证。风险最低。
- **路线 B（可控/长期）**：把 `8ac5168` 补丁集 rebase 到 6.16 基线自行编译（注意 DTS 目录迁移到 `arch/arm/boot/dts/hisilicon/`），可裁剪配置、跟踪安全更新。
- **路线 C（不推荐）**：纯主线化（重写/替代 SDK 驱动），工作量极大，短期不可行。

## 6. 风险与待验证

- [ ] 预编译 uImage 是第三方构建，需实际刷机验证能否正常启动（串口观察）
- [ ] 该内核无 HDMI/解码驱动，若后续需要显示输出必须回到 SDK 4.4 路线
- [ ] 百兆网口（`phy-mode = "mii"`）为性能瓶颈，做 NAS 需评估
- [ ] `CONFIG_ARM_LPAE=y`：与部分教程“必须禁用 LPAE”的说法相反，若自编译失败可尝试关闭
- [ ] 6.14.3 二进制对应的源码树未在仓库公开，需自行 rebase 才能源码级复现
- [ ] Debian 13 (trixie) armhf 在该内核上的兼容性待实测（建议先 bookworm）
- [ ] 盒载 WiFi 无主线驱动，需外挂模块或改用 USB 网卡

## 7. 参考资料

- 内核移植（推荐）：https://github.com/loonpn/ec6108v9c-linux-kernel
  - 预编译：https://github.com/loonpn/ec6108v9c-linux-kernel/releases/latest
- 同源镜像/分支：https://github.com/itatboy/ec6108v9c-linux-kernel
- 海思 SDK 路线：
  - https://github.com/zjkanjie/HiSTBLinuxV100R005C00SPC060
  - https://gitee.com/lixing865/hi3798m （支持 docker 的 4.4.35）
  - https://github.com/glinuz/hi3798mv100 （含 bootargs.txt / emmc_partitions.xml）
  - https://github.com/hihopeorg/linux-hi3798mv100
- 社区系统与教程：
  - 海纳思系统 https://www.ecoo.top/ ；论坛 https://bbs.histb.com/
  - Debian 刷入实践 https://lorzzn.com/p/848060e4.html
  - Hi3798MV100 板级笔记 https://gitlab.com/TheuTrich/stuffs-with-hi3798mv100-board
- 上游相关（64 位分支，仅供参考）：hi3798mv200 主线补丁与 `hisi_femac` 驱动（LKML net-next，2024）
