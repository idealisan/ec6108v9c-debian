# 027 — 原厂 Android 显示栈静态分析（整机备份离线逆向）

> 2026-11-07 调研。目的：为「将来可能基于原厂安卓重写 / 移植 mainline 风格显示驱动」这条路线**提前摸底**，
> 把分卷整机备份里与显示相关的一手证据固定下来，避免只留在临时目录里白做。
>
> - 对象：`TMP/stock-partition-backups/` 下的分卷备份（EC6108V9C / Hi3798MV100，原厂 Android 4.4.2 整机 eMMC 分区）
> - 方法：**离线解包 + 静态分析**（解 zip / boot.img / uImage / gzip+cpio / ext4 / 字符串与常量扫描），
>   不联网、不刷机、不改真机、不构建镜像、不访问仓库外目录
> - 原始笔记：`TMP/stock-rom-research/RESEARCH-NOTES.md`（`TMP/` 已被 `.gitignore` 排除，不入库；本文自包含）
> - 相关文档：`docs/005`、`docs/013`、`docs/021`、`docs/022`、`docs/023`、`docs/024`、`docs/025`
>
> **结论先行**：备份里**没有可复用的显示 `.ko` 模块**，显示栈**编进 3.10 内核** ——
> 移植时**不存在「搬一个 `.ko` 点亮屏幕」这条路**；配有一整套**专有 Android 用户态 HAL**（不可在 mainline 直接复用）。
> 因此本备份的价值是「一份真实、可反汇编的一手规格」
> （实际刷入的 hiboot 二进制 + 生产内核 + 寄存器常量 + API 面 + 参数表），**不是可直接搬的驱动源码**；
> 寄存器初始化序列须从 vmlinux / hiboot 反汇编提取，源码基线仍来自 HiSTB SDK（`TMP/sdk-src/`）
> 或 histb-mainline 补丁（`TMP/histb-ref/`）。

---

## 0. 一句话结论

显示驱动内建、无显示模块 —— **移植时不存在「搬一个 `.ko` 点亮屏幕」这条路**，只能从 vmlinux / hiboot
反汇编提取寄存器初始化序列；时序来自**运行时 EDID**；hiboot 负责一次性点亮；专有 HAL 不可直接复用。
这份备份能**交叉验证并补强** `docs/021`–`docs/023` 的寄存器 / 时序 / 初始化序列结论，
并暴露三处与既有文档需要对齐的差异（见 §5.2）——其中 `docs/025` §8「外挂 sii9134」的一条结论
被 hiboot 里片内 HDMI TX 的证据**直接推翻**，单列于 §6。

---

## 1. 归档构成与完整性

### 1.1 分卷与合并

| 文件 | 大小（字节） |
|---|---|
| `ec6108v9c-stock-ROM-backup.z01` | 1,950,000,000 |
| `ec6108v9c-stock-ROM-backup.z02` | 1,950,000,000 |
| `ec6108v9c-stock-ROM-backup.zip` | 637,190,572 |
| 合计 | 4,537,190,572 |

合并方式（全部产物写在 `TMP/stock-rom-research/` 下）：

1. 直接 `cat .z01 .z02 .zip > full.zip` 字节数精确，但分卷包中央目录的「磁盘号」字段非零，
   `unzip` 报 `bad zipfile offset`、Python `zipfile` 报 `span multiple disks`，均拒绝读取。
2. 正确做法：`zip <split>.zip -s 0 --out merged.zip`（Info-ZIP unsplit，纯拷贝不重压缩）
   → 4,537,190,580 B。
3. `unzip -t merged.zip`：**全部 21 项 CRC 通过（No errors detected）**；`unzip -l` 干净无多卷警告；
   Python `zipfile` 可读。
4. 按需要**只解出** README、BACKUP.log、p01–p12、p15_system（约 671 MB）；
   p13_backup / p14_cache / p16_userdata（约 7 GB）**未展开**，避免全量展开占磁盘。

### 1.2 条目清单（21 项）

顶层目录 `ec6108v9c-stock-ROM-backup/` 下：

- 元数据：`README.txt`（2,563 B，偏移表与恢复命令）、`BACKUP.log`（4,984 B，分区表 + 每文件 md5 + 实时 cmdline）
- 16 个分区镜像（userdata 按 FAT32 4 GB 上限拆 3 段，故共 18 个 `.img`）：
  `p01_fastboot` `p02_bootargs` `p03_recovery` `p04_deviceinfo` `p05_baseparam` `p06_pqparam`
  `p07_logo` `p08_fastplay` `p09_misc` `p10_factory` `p11_kernel` `p12_iptv_data`
  `p13_backup` `p14_cache` `p15_system` `p16_userdata_a/b/c`
- 未压缩总大小 7,818,190,203 B ≈ 7.28 GiB，与 `BACKUP.log` 里 `/proc/partitions` 的
  `mmcblk0 = 7,634,944 KB` 一致。

### 1.3 与既有记录的差异（归档层面）

- `docs/005` §9 记「16 个分区 + eMMC boot0/boot1，共 17 个文件、7.3 GB」。
  **本归档里没有 boot0 / boot1 镜像**；但 `BACKUP.log` 的 `/proc/partitions` 里确实列出
  `mmcblk0boot0` / `mmcblk0boot1`（各 4096 KB = 4 MiB）→ eMMC boot 区**未纳入这份 zip**。
- userdata 拆为 `_a/_b/_c`（2048 + 2048 + 2058 MiB），`README.txt` 给出拼接后应为 6,452,936,704 B。

### 1.4 md5 与完整性提示（恢复前必读）

`BACKUP.log` 末尾有每文件 md5（日志因两个进程并发写而整段重复）。核对抽出的 9 个文件：

- **8 个完全吻合**（p01 / p02 / p05 / p06 / p07 / p08 / p11 / p15）。
- **p03_recovery.img 不吻合**：日志记 `12dbf844fb38c505a1230277ba22abc9`，
  归档抽出为 `b15255a200dff986064f3a1d414b6956`。但 `unzip -t` 对该条 CRC 通过，
  说明「归档内存的就是这个文件」，是**日志 md5 与归档内容对不上**，不是解压损坏。
- `BACKUP.log` 正文另有 `skip p01_fastboot … skip p12_iptv_data` 十二行，说明 p1–p12 由另一次抓取补入，
  与记 md5 的那次未必同源。

**【存疑点，不下断言】** 上面的「不同源」只是对现象的一种推测，未获证实。本文只记录三项可复现的观测事实
（p03 的 boot.img 位于 8 MiB 偏移、md5 与日志不符、前 8 MiB 为计数器填充），**不对其成因下断言**。
→ **若用此备份做恢复 / 回滚源，p03 必须先复核**；且须补齐 boot0/boot1（见 §1.3）。

---

## 2. 分区布局 / LBA

### 2.1 原厂 16 分区（`README.txt` 偏移表，与 `docs/005` §3、`docs/013` §7、`docs/025` §5.5.1 完全一致）

| 分区 | 名 | 大小 | 偏移（字节） | 偏移（MiB） |
|---|---|---|---|---|
| p1 | fastboot | 1M | 0 | 0 |
| p2 | bootargs | 4M | 1,048,576 | 1 |
| p3 | recovery | 16M | 5,242,880 | 5 |
| p4 | deviceinfo | 1M | 22,020,096 | 21 |
| p5 | baseparam | 4M | 23,068,672 | 22 |
| p6 | pqparam | 4M | 27,262,976 | 26 |
| p7 | logo | 4M | 31,457,280 | 30 |
| p8 | fastplay | 16M | 35,651,584 | 34 |
| p9 | misc | 8M | 52,428,800 | 50 |
| p10 | factory | 24M | 60,817,408 | 58 |
| p11 | kernel | 12M | 85,983,232 | 82 |
| p12 | iptv_data | 8M | 98,566,144 | 94 |
| p13 | backup | 340M | 106,954,752 | 102 |
| p14 | cache | 340M | 463,470,592 | 442 |
| p15 | system | 520M | 819,986,432 | 782 |
| p16 | userdata | -(剩余) | 1,365,241,856 | 1302 |

`blkdevparts`（**不是磁盘分区表**，由 bootloader 经 bootargs 让内核识别）：

```
1M(fastboot),4M(bootargs),16M(recovery),1M(deviceinfo),4M(baseparam),4M(pqparam),
4M(logo),16M(fastplay),8M(misc),24M(factory),12M(kernel),8M(iptv_data),
340M(backup),340M(cache),520M(system),-(userdata)
```

### 2.2 与 `configs/partition-layout.env`（Debian 目标布局）对照

`configs/partition-layout.env` 是 **8 分区**：

```
1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),20M(kernel),64M(busybox),-(debian)
ROOT_DEV=mmcblk0p8
```

内核写 14 MiB、rootfs 覆盖末尾；原厂 recovery / factory / backup / cache / system 全部被重新定义。
这正是 `docs/005` §8、`docs/013` §4 强调的「布局必须整体切换」；本归档是切换前唯一的原厂回滚源
（但注意 §1.4 的 p03 完整性与 boot0/boot1 缺失）。

### 2.3 p02_bootargs（U-Boot env）实证

结构：4 字节 CRC32 + NUL 分隔 `key=value`。CRC 字段 `0x792AC979`，对 **64 KiB** env 区算 `zlib.crc32`
**精确吻合**（→ env 尺寸 0x10000，与 `docs/025` §5.5.1 的 `bootargs.bin 0 0x10000 0x10000` 一致；
`docs/005` §5「CRC 校验通过」得到复核）。关键变量：

```
bootdelay=0  verify=n  baudrate=115200
bootcmd=mmc read 0 0x1FFBFC0 0x4B000 0x5000; bootm 0x1FFBFC0
bootargs=console=ttyAMA0,115200 blkdevparts=mmcblk0:<16 分区>
bootargs_512M=mem=512M mmz=ddr,0,0,235M
bootargs_1G=mem=1G   mmz=ddr,0,0,400M
bootargs_2G=mem=2G   mmz=ddr,0,0,600M
phy_intf=mii,rgmii  use_mdio=0,1  phy_addr=2,1  gmac_debug=0
stdin/stdout/stderr=serial
signature_check=sign:recovery,recovery,0x200000 sign:kernel,kernel,0x700000
```

`mmz=ddr,0,0,400M` 是**媒体内存区（MMZ）**，显示 / 解码共用；
`docs/022` / `docs/023` 讨论的显存分配即出自这里。

`BACKUP.log` 还给出实时 `/proc/cmdline`：
`coherent_pool=2M console=ttyAMA0,115200 blkdevparts=<16 分区> mem=1G mmz=ddr,0,0,400M`
—— `mem=1G mmz=...` 来自 env 的 `bootargs_1G` 合并，**不在 boot.img 自带 cmdline 里**（印证 `docs/013` §7）。
内核为 `Linux 3.10.0_s40`（2018-06-30 构建，构建机标识见 `docs/005` §6 / `BACKUP.log`）。

---

## 3. boot / recovery 镜像结构

### 3.1 p11_kernel.img —— 正常启动的 Android boot.img

`file` 直接识别为 `Android bootimg`。头（v0，page_size 2048）与 `docs/013` §7 **精确吻合**：

| 字段 | 值 | 备注 |
|---|---|---|
| magic | `ANDROID!` | header_version=0 |
| kernel_size | 7,898,576 (0x7885D0) | 文档十六进制一致，其十进制 7,899,600 为笔误 |
| kernel_addr | 0x03E08000 | |
| ramdisk_size | 334,473 (0x51A89) | |
| ramdisk_addr | 0x04E00000 | |
| second_size / addr | 0 / 0x04D00000 | |
| tags_addr | 0x03E00100 | |
| page_size | 2048 | |
| **dt_size** | **0** | **无追加 DTB**（Android 4.4 + ATAG，`docs/005` §6） |
| name | 空 | |
| cmdline | `coherent_pool=2M console=ttyAMA0,115200 blkdevparts=<16 分区>` | 无 `root=` / `mem=` / `mmz=` |

文件内偏移：kernel@0x800、ramdisk@0x789000、second/dt 同处 0x7DB000。

- **kernel**：uImage 包装（`Linux-3.10.0_s40`，os=linux / arch=arm / type=kernel / comp=none，
  load=ep=0x02000000，构建时间 2018-06-30）。payload 以 ARM NOP sled（`mov r0,r0` 重复）开头，
  内嵌 gzip 的 zImage piggy（偏移 0x5894），**解压出 17,432,904 B 的 vmlinux**（5 万+ 条可打印字符串），
  是一手的内核侧显示证据来源。
- **ramdisk**：gzip + cpio(`newc`)，621,568 B，**25 项**：`init`(196,780)、`init.rc`(25,360)、
  `init.bigfish.rc`(9,388)、`init.environ.rc`、`init.trace.rc`、`init.usb.rc`、
  `ueventd.rc` / `ueventd.bigfish.rc`、`default.prop`、`sepolicy`(74,844)、
  `file_contexts` / `property_contexts`、`sbin/{adbd,healthd,ueventd,watchdogd}` 等。
  **没有任何显示 `.ko`**。

### 3.2 p03_recovery.img —— 结构异常，boot.img 在后半槽

- 前 8 MiB **不是** `ANDROID!`：从 0 起是**单调递增的 32 位计数器填充**
  （起始 `0x00017881`，每 4 字节 +1），非零区延伸到约 0x500103，其后到 0x7FFFFF 全 0。
- `ANDROID!` 出现在 **0x800000**（第 2 个 8 MiB 槽）；内核为 xz 压缩、ramdisk 为 gzip。
  → 16 MiB recovery 分区里，真正可用的 boot.img 在**后半槽**。
- 结合 §1.4 的 md5 不符与 `BACKUP.log` 的 `skip p01..p12`，**一种推测**是
  p1–p12 与记 md5 的那次抓取不同源（recovery 前半被写入过测试 / 填充内容）——
  **此项标为存疑点，不下断言**（详见 §1.4）。恢复前须复核。

p03 @0x800000 的 boot.img 头：

| 字段 | 值 |
|---|---|
| kernel_size | 2,563,176 (0x271C68) @ 文件 0x800800 |
| ramdisk_size | 957,395 (0xE9BD3) @ 文件 0xA72800 |
| kernel / ramdisk / tags addr | 0x03E08000 / 0x04E00000 / 0x03E00100 |
| page_size / dt_size | 2048 / 0 |
| cmdline | `console=ttyAMA0,115200 blkdevparts=<16 分区>`（**无** `coherent_pool=2M` 前缀，与 p11 不同） |
| uImage | `Linux-3.10.0_s40`，**构建时间 2016-05-23**（比 p11 老两年），load 0x02000000 |

ramdisk：gzip cpio → 1,612,800 B，**52 项**：`sbin/recovery`(445,036)、`init.rc`(1,465)、
`etc/recovery.fstab` / `etc/recovery.emmc.fstab`、`res/images/*.png`（`icon_installing*`、
`indeterminate01..06`、`installing_text`、`erasing_text`、`error_text`、`no_command_text`、
`progress_empty/fill`、`icon_error` 等）、`res/keys`、`default.prop`、`sepolicy`、`ueventd.*`。
**没有 `font.png`**。`init.rc` 只有 3 个 service：`ueventd` / `recovery` / `adbd`
（无 surfaceflinger / minui 服务），与 `docs/023` §2 一致：老式 recovery 由 `/sbin/recovery` 进程内直接画。

### 3.3 与 `docs/023` 的逆向不是同一份 recovery 镜像

`docs/023` 的对象是 `backup_stock/p3_recovery.img.gz`，记录 kernel 2,822,648 B / ramdisk 1,309,209 B、
ramdisk 含 `res/images/font.png`。本归档 p03 为 kernel 2,563,176 B / ramdisk 957,395 B、
含 `error_text.png` / `no_command_text.png` 而**无 font.png**、构建年份 2016。
→ 两者是**不同 recovery 构建 / 不同抓取**，数值不可直接互引；
但 `docs/023` 的**定性结论**（fbdev 画字、无 surfaceflinger、依赖内核已注册 fb0）在本归档里依然成立。

---

## 4. 显示相关证据（研究重点）

### 4.1 内核侧：显示驱动「内建」，不是可加载模块

p11 解压出的 vmlinux 含 **361 条**显示相关符号 / 字符串，例如：

```
HI_DRV_PDM_Init / DRV_PDM_GetDispParam
HI_DRV_PQ_Init / DRV_PQ_UpdateVdpCSC / DRV_PQ_UpdateVpssPQ
HI_DRV_HDMI_GetSinkCapability / DRV_HDMI_Read_EDID / DRV_HDMI_SetVOAttr / DRV_HDMI_GetInfoFrame
hdmi_SoftResume / hdmi_Create_AVI_Infoframe / HDMI_TX_PHY_BASE_ADDR
hifb_logo_init / HIFB_WBC2_OpenSlvLayer / layersize hifb0..hifb5
OPTM_VDP_SetDCMPStride / mmz_userdev_{open,mmap,ioctl}
/proc/msp/*（121 条）/ reserved vesa display device / baseparam / pqparam
```

p15 的 `/lib/modules/` 共 **16 个 `.ko`**：
`ath6kl_usb`、`cfg80211`、`cfg80211_ath6k`、`create`、`ehci-hcd`、`ohci-hcd`、`xhci-hcd`、
`tntfs_hisilicon`、`mt7601Usta`、`mtprealloc7601Usta`、`rtl8188eu`、`rtl8188fu`，
以及 `bcm20705/` `csr8510/` `mt76x2u/` `rtk8xxx/` 下的 `btusb.ko`
—— **全是 WiFi / USB / 蓝牙 / 文件系统，零个显示模块**。
`init.bigfish.rc` 的 `on property:sys.insmod.ko=1` 也只 insmod 这些。

> **结论（最关键）**：显示驱动全部编进内核、`/lib/modules/` 里 16 个 `.ko` 无一与显示相关。
> **它的含义**：将来基于原厂安卓移植显示驱动，**不能指望「搬一个 `.ko`」**——根本没有可拷的模块；
> 唯一可行的路径是从本备份解出的 **vmlinux 与 hiboot 二进制里反汇编提取寄存器初始化序列**
> （`HDMI_Display()` / `TX_PHY_*` / VO 图层配置），再与 SDK 源码逐字节核对；
> 专有 Android HAL 是用户态 `.so`，按 pmOS 的结论不可在 mainline 直接复用（`docs/025` §1.2）。
> 显示侧的源码基线仍须来自 HiSTB SDK（`TMP/sdk-src/`）或 histb-mainline 补丁（`TMP/histb-ref/`）。

### 4.2 寄存器基址：二进制里的直接证据

对 vmlinux 与 p15_system 做 4 字节小端常量搜索（命中数远超随机，均为真实常量）：

| 常量 | p11_vmlinux | p15_system | 含义 |
|---|---|---|---|
| `0xf8cc0000` | ≥12 处 | ≥12 处 | VO/VDP 寄存器基址（`docs/023` §4.2 `CONFIG_VDP_REG_BASEADDR`） |
| `0xf8ce0000` | 0 | ≥12 处 | HDMI TX 基址（`docs/022` §3 / `docs/023` §4.4） |
| `0xf9000000` | ≥12 处 | ≥12 处 | VO/VDP 备用区（fbprobe 定义） |
| `0xf8ce1800` | 0 | 0 | HDMI PHY（未见显式 4 字节常量） |

→ **实测印证 `docs/022` / `docs/023` 的寄存器基址**；`docs/025` §3 里 histb `910-02` 板级 DTS 的
`media_cma` 注释提到 `VO_G0_ADDR` 且「显示侧无 MMU」，与这一路寄存器概念同源。

**反向的「缺」**：SDK `drv_pdm.c` 的 `ClkPara0=0x912ccccc` / `ClkPara1=0x006d8157`
（`docs/021` §3 / `docs/022` §4）在 baseparam、vmlinux、p15_system、p01_fastboot、p03_kernel 里**都搜不到**。
→ 那组 fallback 时序 / 时钟常量是 SDK 源码里的，不存在于设备二进制；
如需固定 1080p60 时序表，只能从 SDK `si_vmode.c` / `vmtables.c` 取，**备份里没有**。

### 4.3 设备节点（`ueventd.bigfish.rc` / `ueventd.rc`，p11 与 p03 一致）

```
/dev/hi_disp   /dev/hi_vo     /dev/hi_hdmi    /dev/hi_vpss   /dev/hi_pdm
/dev/hi_pq     /dev/hi_gfx2d  /dev/hi_tde     /dev/hi_png    /dev/hi_jpge
/dev/hi_sethdcp /dev/mmz_userdev  /dev/graphics/fb*  /dev/mali*  /dev/dri/*
/dev/tty0      /dev/pmem       /dev/msm_hw3dm
```

`/dev/dri/*` 印证 `docs/023` §3：完整 Android 图形栈走 DRM/KMS（drmserver），
而 recovery 走传统 fbdev。

### 4.4 init 脚本里的显示服务（p11）

- `init.bigfish.rc`：`service display /system/bin/displaysetting`（注释 `#add display service`）、
  `service hipq /system/bin/pqsetting`、`on property:sys.insmod.ko=1` → 只加载 USB/FS `.ko`。
- `init.rc`：`service surfaceflinger /system/bin/surfaceflinger`（`group graphics drmrpc`）、
  `on property:sys.hmt.msp_hifb0=show` → `write /proc/msp/hifb0 show`、
  `setprop system_init.startsurfaceflinger 0`。
- `init.environ.rc`：`export ANDROID_BOOTLOGO 1`。

### 4.5 recovery 的显示初始化（p03，与 `docs/023` §3 完全吻合）

`/sbin/recovery` 的 strings：

```
/dev/graphics/fb0   cannot open fb0   failed to get fb0 info   failed to put fb0 info
/dev/tty0           can't open /dev/tty0   failed KDSETMODE to KD_GRAPHICS on tty0
```

→ RecoveryUI 走 `open("/dev/graphics/fb0")` + `FBIOGET_*SCREENINFO` + `KDSETMODE/KD_GRAPHICS`，
把 `res/images/*.png` blit 进显存；**完全依赖内核已注册好 fb0，自己不碰寄存器**。
`etc/recovery.fstab` 列出 `by-name/{fastboot,bootargs,recovery,deviceinfo,baseparam,logo,fastplay,misc,factory,kernel,iptv_data,cache,system,userdata,backup}`
挂载点（注意**没有 pqparam**）。

`default.prop`（p03，2016 构建）：`ro.build.display.id=Hi3798MV100-eng 4.4.2 KOT49H eng.root.20160523.121542 test-keys`、
`persist.sys.cvbs.and.hdmi=true`、`stb.multiscreen.ablity=02346`、
`service.media.hiplayer.graphic=false`、`persist.sys.screenorientation=landscape`。

### 4.6 p15_system（ext4）里的专有 Android 显示 HAL / 工具

ext4 参数（自写只读 walker 解析）：4 KiB 块、256 B inode、extents、**无 64BIT**、**无 dir_index**，共 2009 条目。

关键 HAL（`/lib/hw/`）：

| 文件 | 大小 | 关键字符串 |
|---|---|---|
| `gralloc.bigfish.so` | 17,660 | `framebuffer_device_open`、`/dev/graphics/fb%u`、`/dev/fb%u`、`pri_hisi_init_framebuffer(fb_var_screeninfo)` |
| `hwcomposer.bigfish.so` | 13,632 | `HISI_HWC`、`setFbFormat16(HIFB_COLOR_FMT_E)`、`tde_compose`、`ion_phy_addr=0x%x`、"Sample hwcomposer module" |
| `hidisplay.bigfish.so` | 54,696 | `HI_UNF_PDM_GetBaseParam`、`HI_UNF_DISP_GetAspectRatio/GetBrightness`、`HI_UNF_HDMI_GetAttr/SetAttr`、`HI_UNF_HDMI_GetSinkCapability`、HDMI suspend / CEC / HDCP 全套 setter/getter（1018 字符串中 339 条显示相关） |
| `libGLES_mali.so`（`/lib/egl/`） | 1,087,560 | Mali GPU（Mali200 / MaliGP2、`__ARM_MALI__`），Android 3D 合成用，与 VO/HDMI 输出是两回事 |

配套库：`libhi_msp.so`(870,312，`HI_MPI_HDMI_*`、`Hdmi_Poll_Event_Thread`、`Hdmi_CEC_Event_Thread`)、
`libhidisplayclient.so` / `libhidisplayservice.so` / `libhihdcp.so` / `libpqclient.so` /
`libhi_gfx2d.so` / `libhi_png.so` / `libhi_common.so` / `libdrmclientplugin.so` /
`libEGL.so` / `libGLESv1_CM.so` / `libGLESv2.so`。

显示 CLI 工具（`/bin/`）：`displaysetting`、`disptest`（`DisplayClient::Get/SetEncFmt/GetDisplayCapability/GetVirtScreenSize`）、
`pqsetting`、`pq_debug`（`/dev/hi_sys` `/dev/hi_mem` `UMAP_CMPI_*` ioctl）、`msp_debug`、
`sample_edid`、`sample_hdmi_rx`、`sample_hdmi_subplug`、`sample_hdmi_tsplay`、`sample_pq`、
`sample_hdcp_burn` / `sample_encryptHdcpKey` / `sample_otp_*`（HDCP 密钥）、
`bootanimation`、`surfaceflinger`、`equipfile/hdmi.h264`、`test_HDMI.mp3`。

**EDID / HPD 路径（对驱动移植最有用）**：

- `/bin/sample_edid`：`HI_UNF_I2C_Init/CreateGpioI2c/Read`、`HI_UNF_GPIO_*`、
  `HI_UNF_EDID_EdidParse` / `HI_MPI_EDID_EdidParse`、`HI_UNF_DISP_Init/AttachIntf/SetFormat/Open`、
  `HIADP_HDMI_Init`、`HI_UNF_HDMI_ReadEDID`、`HI_UNF_DISP_Close/DeInit`
  → **EDID 走 GPIO 模拟 I2C 读取、解析后交 DISP**，正是 `docs/022` §4 要求的「HPD 检测 + EDID 读取」一手证据。
- `/bin/sample_hdmi_subplug`：
  `HI_UNF_HDMI_EVENT_{HOTPLUG,NO_PLUG,EDID_FAIL,HDCP_FAIL,HDCP_SUCCESS,RSEN_CONNECT,RSEN_DISCONNECT}`
  → 印证 `docs/021` §1 社区系统的 `HDMI kernel event(no UserCallBack): HOTPLUG`：原厂是有 callback 闭环的。
- `/bin/sample_hdmi_tsplay`：`HIADP_Disp_StrToFmt`、`HIADP_Disp_Init`、`HIADP_VO_Init/CreatWin`、
  `HI_UNF_VO_AttachWindow/SetWindowEnable` 等 ADP 层初始化序列。

`/build.prop` 显示属性：`persist.sys.cvbs.and.hdmi=true`、`ro.sys.hw.hdmi.res.autosave=1`、
`persist.sys.hdmi.cec=false`、`persist.sys.bootanim.enable=true`、
`persist.sys.audio.hdmi.output=2`、
`ro.build.display.id=Hi3798MV100-eng 4.4.2 KOT49H 5.2.0.B243SPC003 test-keys`。
另有 `vo_format:2160P_30|2160P_24|1080P_60|1080P_50|1080i_60|[1080i_50]|720P_60|720P_50`
与 `hdmi_*` 调试命令表（`hdmi_display_edid`、`hdmi_video_timing`、`hdmi_reg`、
`hdmi_attach_intf`、`hdmi_hdcp`、`hdmi_color_mode`、`hdmi_set_disp_3d`、`hdmi_deepcolor` 等）。

### 4.7 参数分区：baseparam / pqparam / logo

**p05_baseparam.img**（`###\0` 魔数 + 32 字节键名 / u32 长度 / 值的表结构）—— 设备实际存的显示参数：

- `BASE_TABLE_DISP0`：`SOURCE_DISP=1`、`FMT=11(0xB)`、全部 `TIMING_*`
  （VFB/VBB/VACT/HFB/HBB/HACT/VPW/HPW/IDV/IHS/IVS/CLKR/DW/ITFMT/DITE/CLK0/CLK1/INTERL/FIXF/VERTF/AW/AH）
  **= 0**、`VIRSCW=1280`、`VIRSCH=720`、色彩 `HULEP/SATU/CONTR/BRIG=50`、
  接口 `HDMI0=(9,1,0)`、`CVBS0=(6,0,0)`，以及 `RGB0/YPBPR0/SVIDEO0/BT6560/BT11200/LCD0/VGA0` 等。
- `BASE_TABLE_DISP1`：`FMT=1`、`VIRSCW=1280`、`VIRSCH=720`、`HDMI0=0`（禁用）。
- `BASE_TABLE_HDMI`：`BASE_KEY_EDID_LENTH=0`、**`BASE_KEY_EDID_CONTENT` 512 字节全 0**（未缓存 EDID）。
- 另有 `BASE_TABLE_SOUND0`（含 `SND_HDMI0`）、`BASE_TABLE_PMOC`。

→ **时序值全 0 + EDID 缓存为空**，直接印证 `docs/022` §4 / `docs/023` §4.3：
显示时序**运行时从 sink EDID 读取**（`SinkCap.stPerferTiming`），
`drv_pdm.c` 的 `g_stDispTiming` 只是 HI_LOADER fallback；
也解释了 `docs/021` §1 里社区系统 HOTPLUG 无回调时为何有时不亮。

**p06_pqparam.img**：基本是二进制 PQ 系数表（4 MiB 中约 30 KB 非零，含若干 JPEG 魔数），
无可读字符串 → 对驱动移植价值有限。

**p07_logo.img**（4 MiB）：`###\0` + `LOGO_TABLE` @0x8、`LOGO_KEY_FLAG=1`、
`LOGO_KEY_LEN=0x2E820`(190,496)，首张 JPEG @0x2000，其后多处 gzip/BMP 魔数 → 多张 logo 图打包。
**`/etc/recovery/defaultlogo/logo.img`**（p15 内，81,920 B）同样带
`LOGO_TABLE` / `LOGO_KEY_FLAG` / `LOGO_KEY_LEN`。

**空分区**：`p08_fastplay`（全 0）、`p09_misc`（仅 1 字节非零）、`p10_factory`（全 0）；
`p12_iptv_data` 仅若干 base64 串；`p04_deviceinfo` 仅一条设备 ID 串 → 无显示内容可挖。

### 4.8 p01_fastboot.img —— 实际刷入的 hiboot 二进制（本次最有价值的新增一手材料）

1 MiB hiboot（Fastboot 3.3.0 / U-Boot 分支）里显示相关符号直接可见：

```
PRODUCT_DisplayInit        Logo_Main                  LOGO_TABLE(@0x81BD0)
HI_UNF_HDMI_Init/Open/Start/Close/DeInit            HI_DRV_HDMI_Init/Open/Start/Close/DeInit
HDMI_Display               hdmi_Disp2EncFmt
TX_SetHDMIMode             SW_ResetHDMITX            HW_ResetHDMITX
TX_PHY_4KRisingTime        TX_PHY_HighBandwidth      TX_PHY_WriteRegister      TX_PHY_SwingCtrl
siiSetVideoPath            siiGetVideoPath           SiI_DeepColor_{24bit,30bit,36bit,Off}
```

另内嵌一条 recovery 路径 cmdline：
`coherent_pool=2M mem=1G console=ttyAMA0,115200 initrd=0x2500000,0x1300000 mmz=ddr,0,0,256M root=/dev/ram blkdevparts=<16 分区>`
（`mmz=256M` 与正常启动 `mmz=400M` 不同，另有 `initrd=0x2500000,0x1300000`、`root=/dev/ram`）。

→ `docs/021` §3、`docs/022` §4、`docs/023` §4.3 描述的 hiboot 显示初始化链
（`HI_UNF_HDMI_Open → HDMI_Display`、EDID / AVI InfoFrame、`TX_PHY_*`、
`PRODUCT_DisplayInit → Logo_Main`）**在这份归档里是真实存在的二进制**，
可反汇编提取精确寄存器写入序列，不依赖 SDK 源码复现 —— 这是相对既有文档最大的补强。

### 4.9 发送器形态（片内 HDMI TX vs 外挂 sii9134）

本节只留指针：原厂 hiboot / 内核显示的是**片内 HDMI TX**（`0xf8ce0000`、`HI_DRV_HDMI_*`、
`HDMI_TX_PHY_BASE_ADDR`），这一证据与 `docs/025` §8 的「外挂 sii9134」结论冲突，
且会决定 plan B 选哪套 histb 补丁 —— **单列一节详述，见 §6**。

---

## 5. 与既有文档的对照

### 5.1 吻合（备份给既有结论补上一手二进制证据）

| 文档 | 既有结论 | 本备份的佐证 |
|---|---|---|
| `docs/005` | 16 分区布局 / 偏移 / env / 内核版本 / 整机备份 | 布局、偏移、env、内核版本逐条吻合；env CRC `0x792AC979` 复核通过 |
| `docs/013` | p11 boot.img 头、无 `root=` 的 cmdline、bootargs 模板 | 头字段精确吻合（仅 kernel_size 十进制笔误）；`dt_size=0` 印证无 DTB |
| `docs/021` | 改走驱动移植；SDK 规模；hiboot 显示栈 | p01 里**实见** `PRODUCT_DisplayInit` / `HDMI_Display` / `TX_PHY_*` / `Logo_Main`；vmlinux 内建全部 MPP 显示符号；**无显示 `.ko`** |
| `docs/022` | HDMI TX `0xf8ce0000`、VO `0xf8cc0000`、EDID 决定时序、SDK 时序表 | 三个基址在二进制里实证；baseparam 全 0 时序 + 空 EDID 缓存**强证**「EDID 运行时读取」；SDK `ClkPara0/1` 常量不在设备里 |
| `docs/023` | recovery 走 `/dev/graphics/fb0` + `KDSETMODE`、无 surfaceflinger、VO 寄存器偏移 | `/sbin/recovery` strings、`init.rc`、`ueventd.rc` 全部吻合 |
| `docs/025` | pmOS 方法论、histb-mainline 7.4 已点亮 mv100、simplefb 不稳、改上 DRM | 原厂 env `bootargs_1G` / `verify=n` 与 §5.5.1 引文吻合；**补充**：原厂用户态是专有 HAL，正是 pmOS 所说「搬到 Android userspace、难以复用」的实例。**例外**：§8 的 sii9134 结论被推翻（见 §6） |
| `configs/partition-layout.env` | Debian 8 分区、`mmcblk0p8`、20M kernel | 与原厂 16 分区完全不同，印证「布局整体切换」 |

### 5.2 差异 / 需要对齐（如实保留，不为「好看」隐去）

1. **`docs/005` §9**：记「16 个分区 + eMMC boot0/boot1，共 17 个文件」；归档里**没有 boot0/boot1 镜像**
   （`/proc/partitions` 里存在但未入档）。恢复物料清单需据实修正。
2. **`docs/023`**：分析对象是 `backup_stock/p3_recovery.img.gz`，与**本归档的 p03 不是同一份镜像**
   （kernel / ramdisk 大小、2016 构建、无 `font.png`、含 `error_text` / `no_command_text` 均不同）。
   定性结论仍成立，数值不可直接互引。
3. **`docs/025` §8**：「mv100 用外挂 sii9134 transmitter，不是 on-chip HDMI」这条结论
   与本备份的直接证据**冲突，应视为被推翻**（至少不能再作为选补丁依据）；
   hiboot 里是片内 HDMI TX。详见单列的 §6（含对 plan B 补丁选择的影响）。
4. **归档自身的数据完整性**：p03 的 md5 与 `BACKUP.log` 不符、boot.img 位于 8 MiB 偏移（§1.4 / §3.2），
   `BACKUP.log` 有 `skip p01..p12` 行 → 恢复 / 回滚前必须复核 p1–p12，并补齐 boot0/boot1。

**总体**：备份给 `docs/021`–`docs/023` 的「寄存器基址 / EDID 时序 / hiboot 初始化序列 / fbdev 画字」
补上一手二进制证据；**除 §6 指出的 `docs/025` §8 那条结论被推翻外**，其余核心结论均获佐证。
需要如实保留的是上述三处文档差异 + 一处归档完整性提示。

---

## 6. 片内 HDMI TX vs 外挂 sii9134（本节结论已被 `docs/029` 撤销）

> **⚠️ 重要更正（2026-11-08，后续调研）**：本节的**核心结论不成立，已由
> `docs/029-transmitter-path-resolution.md` 撤销**。当时只有备份二进制、没有
> histb 补丁原文，把 `0xf8ce0000` 误当成"本板片内 HDMI TX"证据，据此错误地
> "推翻"了 `docs/025` §8。拉取 `500-01`/`500-02`/`600-17`/`600-18`/`910-01`
> 补丁原文后的正确结论是：
> - **mv100（含 EC6108V9C）走 SiI9134 发射器**：`500-02` 明写 "The mv100 board
>   reaches its panel through a SiI9134 transmitter"，新建 `sii9134.c` +
>   `hi3798mv100-hdmi.c`；DT 节点 `hdmi@8ce0000`、`hisilicon,hi3798mv100-hdmi`。
> - **`0xf8ce0000` 属于 hi3716cv200**（见 `500-01` binding 第二个 example），
>   mv100 是 `0x8ce0000`。备份里出现 `0xf8ce0000` 属 SDK 多 chip 条件编译常量
>   或 HDMI 输入/RX 侧，不能证明 mv100 **输出**发送器形态。
> - `600-17` 的片内 TMDS 发送器是 **mv200** 的（commit message 首句明确）。
> - SiI9134 字面量 0 命中不能反证：驱动以厂商 IP / glue 文件
>   `hi3798mv100-hdmi.c` 形式存在，板级节点不带该字样。
>
> → `docs/025` §8 的"mv100 走 sii9134"**方向正确**（仅"外挂"措辞不精确），
> 本节的"推翻"是误判。plan B 应取 bridge 链路（`500-01`/`500-02`/`600-18`
> + VDP2 + 板级 DTS + CRG），不取 `600-17`。
>
> **本节以下内容保留作为当时的推理记录与一手证据清单，不再作为结论依据。**
> 其"先厘清发送器形态再定补丁基线"的方法论要求本身是对的，正是 `docs/029`
> 完成的工作。

### 6.1 原厂备份里的证据（片内 HDMI TX）

| 证据 | 出处 |
|---|---|
| `HDMI_Display`、`hdmi_Disp2EncFmt`、`TX_SetHDMIMode`、`SW_ResetHDMITX`、`HW_ResetHDMITX`、`TX_PHY_{4KRisingTime,HighBandwidth,WriteRegister,SwingCtrl}`、`HI_UNF_HDMI_*` / `HI_DRV_HDMI_*` | `p01_fastboot.img`（实际刷入的 hiboot） |
| `HDMI_TX_PHY_BASE_ADDR`、`DRV_HDMI_*`、`HI_DRV_HDMI_GetSinkCapability`、`hdmi_Create_AVI_Infoframe` | p11 解出的 vmlinux |
| `0xf8ce0000` 常量 ≥12 处（HDMI TX 基址）、`0xf8cc0000` VO/VDP 基址 | p15_system 二进制（§4.2） |
| SDK `drv_reg_proc.h` 的条件分支明确含 `CHIP_TYPE_hi3798mv100`，`HDMI_TX_BASE_ADDR=0xf8ce0000` | `docs/022` §3 / `docs/023` §4.4（源码侧） |

另外：全库检索 `sii9134` 字面量 **0 命中**；`9134` 在 vmlinux 1 次、p15 6 次（疑似无关数字）；
vmlinux 里的 `/proc/msp/sil9293`（SiI9293）与 `SiI_CEC_SetCommand` 更像 **HDMI 输入 / 切换侧**；
hiboot 里的 `siiSetVideoPath` / `SiI_DeepColor_*` 对应 `docs/022` §4 的 `siiSetVideoPath() / SetIClk()`，
是**片内 HDMI TX IP 的 Silicon Image 系列辅助函数**，不是外挂 sii9134 芯片驱动。

### 6.2 与 `docs/025` §8 的冲突（~~该结论被推翻~~ → 本节推翻有误，见 `docs/029`）

`docs/025` §8 写：「**mv100 用的是外挂 sii9134 transmitter，不是 on-chip HDMI**」，
并据此说 `600-17` 的 `histb-hdmi.c` 是 mv200 的片内发送器、我们板子对应
`drivers/gpu/drm/bridge/hi3798mv100-hdmi.c`。

本备份的 hiboot + 内核 + 系统二进制一致指向**片内 HDMI TX（0xf8ce0000）**，
没有任何 `sii9134` 字面证据 → **「mv100 用外挂 sii9134、不是片内 HDMI」这条具体结论被直接推翻**，
不应再作为选补丁的依据。（`docs/025` 内部对 `600-17` 的定位也自相矛盾：
§3.4 把它列为「on-chip HDMI transmitter driver」，§8 又说它是 mv200 的。）

### 6.3 但仍「尚需厘清」的部分（不下断言）

- histb 补丁里 `500-02`（`drm/bridge: add the sii9134 hdmi transmitter`）究竟面向哪块板 / 哪一路
  （HDMI 输入、另一板型、还是本板输出），本地 `TMP/histb-ref/` 只有 4 份补丁，**不含 `500-02` 原文**。
- `600-18` 所依赖的 `hi3798mv100-hdmi.c` 创建补丁不在本地已存的 4 份里，需从
  `histb-mainline/patches/series` 补齐后才能判断它是片内 TX 驱动还是 bridge 驱动（`docs/025` §8 已提示）。
- 是否同板并存片内 TX 与 SiI9293（RX / 开关）两条路径，备份无法排除。
- → 因此本节**只推翻 §8 那条具体结论**，不对「硬件最终形态」下最终断言。

### 6.4 对 plan B 选补丁的直接影响

| 若输出走 | plan B 应取的补丁路径 | 取错的后果 |
|---|---|---|
| **片内 HDMI TX（备份支持）** | 片上发送器链路：`600-17`（`histb-hdmi.c`）/ `600-18`（video path up）+ 补出 `hi3798mv100-hdmi.c` 的创建补丁；配 `910-*` EC6108V9C 板级 DTS 的 `&hdmi status=okay` / `media_cma`、`400-02` CRG 时钟 | 见下 |
| 外挂 sii9134（§8 的说法） | bridge 链路：`500-02` sii9134 + 对应 dt-binding | 见下 |

**选错的代价**：DRM 驱动绑到不在视频通路里的发送器，`VIDEO_PATH` / PHY 没被正确拉起 →
「能编译但黑屏」，正是 `docs/025` §2.2 里 odin `0008` 修的那一类坑，也和本项目当前症状同类。
→ **在锁定 plan B 的补丁基线之前**，先做两件事：
(1) 读 `histb-mainline/patches/series` 补齐 `hi3798mv100-hdmi.c` 创建补丁与 `500-02` 原文，确认各自 `compatible` 与目标板；
(2) 用本备份的 `0xf8ce0000` 片内 TX 事实交叉验证，再决定取片上链路还是 bridge 链路。

---

## 7. 若将来真走「基于原厂安卓重写显示驱动」

### 7.1 关键输入清单

**A. 备份里已拿到（本次新增；分析产物在 `TMP/stock-rom-research/`，gitignored 不入库）**

| 输入 | 用途 |
|---|---|
| p11 解压出的 vmlinux（17.4 MB） | 内核显示栈符号表 / printk / proc 接口全图；可反汇编出寄存器读写序列、ioctl 号、proc 节点名 |
| `p01_fastboot.img`（hiboot 二进制） | **可反汇编的显示初始化序列**：`HDMI_Display` / `TX_PHY_*` / `PRODUCT_DisplayInit` / `Logo_Main`；含 `mmz=256M` 的 recovery cmdline |
| p11 / p03 的 ramdisk 及解出的 `init*.rc`、`ueventd*.rc`、`default.prop`、`fstab` | 设备节点清单、显示服务、fb0 / tty0 用法、分区挂载语义 |
| `p05_baseparam.img`（已解析键值） | 真实 DISP 参数（1280x720、接口使能位、色彩值）、`BASE_TABLE_HDMI` EDID 为空 |
| `p07_logo.img` / `/etc/recovery/defaultlogo/logo.img` | `LOGO_TABLE` 结构与 logo 图，用于理解 hiboot 画 logo 时 VO 图层帧缓冲格式 / 尺寸 |
| p15 文件树 + 提取的 HAL / 工具 | gralloc / hwcomposer / hidisplay / libhi_msp / sample_edid 的 **API 面与命令序列**，可作驱动行为规格 |

**B. 仓库里已有（无需从备份再取）**

- `docs/021`–`docs/025`：路线决策、SDK 盘点、寄存器偏移、上游成果、pmOS 方法论
- `TMP/sdk-src/`（HiSTB SDK 显示栈源码）、`TMP/sdk-tree.json`、
  `TMP/histb-ref/`（histb 7.4 关键补丁）、`TMP/histb-pending.json` / `TMP/histb-hack.json`
- `patches/kernel/hi3798mv100-hdmi-console.c`（第一阶段 simplefb 交接驱动，已编译通过）
- `configs/partition-layout.env`、`scripts/build-kernel.sh`、
  `console=tty0` / fbcon / pstore / 绿带启动标记等既有改动

**C. 仍然缺 / 需要继续做的**

1. **反汇编**：本次只做字符串 / 常量静态分析，**未反汇编** p01_fastboot 与 vmlinux；
   要拿「精确寄存器写入序列」需对这两者做 ARM 反汇编（比读 SDK 更贴近实际刷入的固件）。
2. **固定 1080p60 时序表与 PHY 参数**：SDK `si_vmode.c` / `vmtables.c` 尚未拉全；
   SDK `ClkPara0/1` 常量在设备二进制里不存在，备份帮不上，必须从源码 / 上游补丁取（`docs/022` §6 待确认清单）。
3. **VO/VDP GFX 层寄存器精确偏移**：`hi_reg_vdp.h`（`docs/023` §4.2 已推 `G0_ADDR=+0x494` 等）；
   备份只给基址常量，不给结构体定义。
4. **HPD / EDID 在 6.x 下的实现**：走 `drm_edid` 还是自写 I2C/DDC，`docs/022` §6 仍是待办。
5. **时钟名字（crg clock id）**：`docs/025` 的 `400-01` / `400-02` CRG 驱动；
   备份只有 `clk_ignore_unused` 层面的间接证据。
6. **片内 HDMI TX vs 外挂 sii9134 的厘清**（§6），决定 plan B 采用哪套 histb 补丁。
7. **EDID 实际内容**：baseparam 缓存为空，需从显示器读或真机运行时抓。
8. **真机验证**：本机无串口，只能 SSH / HDMI 观察（`docs/025` §5.5.3 已定「刷机方式不是瓶颈」）。
9. **恢复源一致性**：p03 的 md5 / 8 MiB 槽异常、boot0/boot1 未入档 —— 回滚前须复核补齐。

### 7.2 建议下一步（提前研究，不阻塞主线）

1. **反汇编提序列**：把 `p01_fastboot.img` 与 p11 解出的 vmlinux 做 ARM 反汇编，提取
   `HDMI_Display()` / `TX_PHY_*` / `PRODUCT_DisplayInit` 的寄存器写入序列，
   与 SDK `hdmi_1_4/hdmi.c` 的 **`HDMI_Display()` 逐字节核对**
   （pmOS / odin 经验：**初始化序列要逐字节来自原厂资产，不要手写猜**，`docs/025` §2.2）。
2. 用户已拍板主线移植；`histb-mainline` 7.4 的 DRM 驱动（600 / 910 / 400 / 500 系列）是「别人验证过的组合」。
   本备份更适合作为**交叉验证 / 补寄存器细节**的输入，而不是另起炉灶从 Android HAL 重写
   （HAL 是专有 `.so`，pmOS 明确指出不可直接复用，`docs/025` §1.2）。
3. **先厘清发送器再定基线**：按 §6 先确认片内 HDMI TX 与 sii9134 各自的适用对象，
   再决定 plan B 取片上链路（`600-17` / `600-18`）还是 bridge 链路（`500-02`），
   不要先挑补丁后补证据。
4. 第一阶段 simplefb 交接（`docs/022` §6.1 / `docs/024`）仍在验证中；
   **仅当真机证明它不足时**才启用本调研对应的「自己初始化显示硬件」第二阶段，
   避免与主线工作抢资源。
5. 所有恢复 / 回滚操作前，先核对 p03 与 boot0/boot1；`README.txt` / `BACKUP.log` 是权威偏移表。

---

## 8. 复现与方法

分析全程只用轻量静态手段，产物一律放在 `TMP/stock-rom-research/`（`.gitignore` 排除，不入库）：

| 产物 | 用途 |
|---|---|
| `rtools.py` | boot.img / uImage 头解析、gzip、cpio newc、字符串与关键字扫描公共函数 |
| `step1_bootimgs.py` + `step1.log` | 解析 p11 / p03 两个 boot.img，抽 kernel / ramdisk，解压 zImage→vmlinux，列 cpio |
| `step2_ext4.py` + `step2.log` + `p15_filelist.txt` | 最小只读 ext4 walker（32 位组描述符 / 线性目录 / extents），列出 p15 全树 |
| `step3_files.py` + `step3.log` + `p15_display_strings.txt` | 抽 HAL / 工具并扫字符串；全库搜 `0xf8cc0000` / `0xf8ce0000` / `0xf9000000` 等常量 |
| `step4_raw.py` + `step4.log` | 解析 p01–p12 原始分区、U-Boot env、LOGO_TABLE、baseparam 键值 |
| `RESEARCH-NOTES.md` | 原始完整笔记（本文为其正式归档版，原文保留不动） |

方法与合规说明：

- 分卷用 `zip -s 0 --out` 合并并全量 CRC 校验通过；**未全量展开**（只解出 p1–p12 + p15）。
- **未**运行 `rm` / `git clean` / 镜像构建（`mke2fs` / `debootstrap` / `img2simg` 等一律未用）。
- **未**修改任何已跟踪文件、未 `git add` / commit / push / 建分支、未动 git 索引；
  本文为 `docs/` 下新建文件，由主会话统一提交。
- 描述本地资源一律用仓库内相对路径（如 `TMP/stock-partition-backups/`）或通用占位；
  原始抓取介质为**本地外置盘，未入库**，本文不记录其卷名 / 挂载路径 / 任何可识别本机的私有信息。
- 原厂内核里携带的厂商构建机绝对路径 / 构建用户标识已刻意省略，未写入任何文件。
- 本文落盘前对「绝对路径 / 本机用户名 / 卷名 / 可识别本机的私有信息」逐项 grep 自查，确认干净。
