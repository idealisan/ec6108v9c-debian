# 053 — 主线 6.x 刷机包真机验证 SOP（一次性给出可判定信号）

> 2026-11-09。配合 U 盘 `README-VERIFY.txt`。目标包：6.3 主线内核 + Debian rootfs，
> recovery-flasher 方式刷入（p2/p5/p6/p8 绝对 LBA，p1 fastboot 永不写）。
> 本文的目的：把「能引导 / 能显示 TTY / 能连网」三个目标拆成**互相独立、可分别观测**
> 的判据，让你一次刷机就能告诉我卡在哪一级，我据此进入下一轮修改，不再盲试。

## 0. 静态侧已排除的嫌疑（不用再查，节省时间）

- 内核源 = 6.3.0-rc5 主线（`third_party/linux-hi3798mv100`，Makefile VERSION=6/PATCHLEVEL=3，
  loonpn/ec6108v9c-linux-kernel），非 7.4-histb / 非 4.4-ecoo 下游内核。
- uImage magic/CRC 自洽，`load=entry=0x02000000` 与 hiboot
  `bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0` 对得上（0x1FFFFC0 + 0x40 header）。
- appended DTB 位于 payload 末尾、`totalsize` 合法；`/chosen/bootargs` 全项齐：
  `mem=1G`、`root=mmcblk0p8`、`console=tty0 console=ttyAMA0,115200`、
  `fbcon=map:0`、`blkdevparts`（8 分区）、`clk_ignore_unused`；`/memory@0 reg=<0x0 0x40000000>`
  与 `mem=1G` 一致。
- `CONFIG_ARM_APPENDED_DTB=y` + `CONFIG_ARM_ATAG_DTB_COMPAT=y`（defconfig 自带，兼容 hiboot ATAG）。
- TTY 链配置齐：`CONFIG_VT/FRAMEBUFFER_CONSOLE/FONT_8x16/FB_SIMPLE=y` + `console=tty0` + `fbcon=map:0`。
- 网络链配置齐：`CONFIG_HISI_FEMAC/MDIO_HISI_FEMAC/PHYLIB=y` + rootfs `eth0` DHCP/systemd-networkd。
- 默认路径显示驱动 `hi3798mv100-hdmi-console.c` 的 VO G0 寄存器偏移已按 FINDINGS §D 修正为
  `+0x6010/0x601c/0x6020`、`ioremap 0xfff0`（旧 `+0x494` 是读 GP1_PARARD 的误算）。

**这些只证明"配置没明显错"，不证明内核真的执行到了。** 运行时是/否必须真机。

## 1. 刷机前（电脑上）

1. U 盘 FAT32/MBR，根目录含：`fastboot.bin`（社区 carrier，**必须保留**）、`bootargs.bin`、
   `recovery.img`、`flash.manifest`、`mv100/`（hi_kernel.bin / logo.img / bootargs.bin / debian-root.ext4）。
2. 确认 `flash.manifest` 4 项、p1(LBA 0) 不写；`mv100/hi_kernel.bin` 是 6.x 主线 uImage
   （`linux-hi3798mv100`）。
3. 断电，插 U 盘。

## 2. 刷机阶段（短接上电）

- 短接触点 → 上电，BootROM 加载 U 盘 `fastboot.bin`。
- 屏幕应出现**终端式滚动日志**（`1 BOOT OK` … `6 DONE NO REBOOT`），按绝对 LBA 写 p2/p5/p6/p8。
  这一阶段已真机验证可用。
- 刷完停在 `6 DONE NO REBOOT`。**断电、拔 U 盘**。

### 刷机阶段异常
| 现象 | 含义 | 下一步 |
|---|---|---|
| 一直黑屏、无背光 | 没进刷机模式（触点/上电时序） | 断电重试；拔盘能否正常进社区系统 |
| `7`/`70` NODE/MOUNT | U 盘节点或挂载失败 | 换 U 盘口/FAT32 重格 |
| `8 NO MANIFEST` | 没读到 flash.manifest | 确认文件在 U 盘根、命名精确 |
| `9 NO EMMC` | eMMC 节点缺失 | 报日志 |

## 3. 正常开机（拔盘、断电开机）—— 三级判据，请分别记录

> 关键：请把**每一级的结果**都告诉我，不要只说"没显示"。黑屏时三级信号能区分
> 「内核没起」还是「内核起了但显示/网络没绑」，这决定我下一轮改哪里。

### L0 — 内核到底起来了没（优先级 0，先于一切显示/调参）
- **绿带**：屏幕顶部出现纯绿粗带 = 内核跑到了显示驱动的 `subsys_initcall`。
  （绿带是 L0 探针，不是最终显示方案；TTY 文字出现后会被覆盖。）
- **pstore**：若黑屏，断电重启进社区系统（`ssh root@<ip>`），读
  `cat /sys/fs/pstore/dmesg-* /sys/fs/pstore/console-* 2>/dev/null`，
  找 6.x 的 `Linux version 6.3`、`hi3798-fb: VO layer0: addr=...` 或早期 `printk`/panic。
  有内核日志 = 内核起来了（哪怕没显示）。
- 判据：`绿带出现` 或 `pstore 有 6.x 日志` = **L0 过**；
  `始终只有 Debian Linux logo + 浅蓝细线、pstore 空` = **L0 没过（内核没起来）**。

### L1 — 能显示 TTY（本阶段目标）
- HDMI 出现内核启动文字（`[ 0.000000] Linux version ...`）、彩色条纹、或 `login:` 提示符。
- 判据：`有文字/彩色条纹` = **L1 过**（显示驱动 + framebuffer + fbcon 绑定全通）；
  `只有绿带无文字` = 内核起来了但 fbcon 没绑（另查 `fbcon=map:0` / fbdev 注册）。

### L2 — 能连网
- 路由器后台 DHCP 列表出现新 IP；或 `ssh root@<ip>` 通。
- 判据：`新 IP/SSH 通` = **L2 过**（内核 + rootfs + userspace + 网络全通）。

## 4. 结果 → 我下一轮改什么（对照表）

| L0 | L1 | L2 | 结论 | 我下一步 |
|---|---|---|---|---|
| ✗ | ✗ | ✗ | 内核没启动到 userspace | 查启动链：uImage 装载/DTB/ATAG 交接/early panic；**不调显示**（方向错误） |
| ✓ | ✗ | ✗ | 内核起了，显示未绑 | 查 framebuffer 注册 / fbcon 绑定 / VO G0 显存地址（+0x6010 真机读值） |
| ✓ | ✓ | ✗ | 显示通，网络未通 | 查 hisi_femac probe / DTS eth0 / rootfs DHCP |
| ✓ | ✓ | ✓ | **目标达成** | 固化 + 去掉过渡绿带 |

## 5. 请把结果按这个格式发我

```
刷机阶段: 正常到 6 / 异常(贴数字或现象)
L0 绿带: 有/无   pstore 6.x 日志: 有/无(贴前几行)
L1 HDMI 文字/彩色条纹: 有/无(贴看到什么)
L2 路由器新 IP / SSH: 有/无
```

## 6. 仍待真机的 [未知]（不假装已定）
- VO `0xf8cc6010` 此刻的 MMIO 读值是否等于 `HIFB_DispBuf_HD`(≈0x3f6ce000)、跨次是否稳定。
- EDID / HPD / 显示时序（sink 运行时读）——私有驱动完整点亮 HDMI 序列的前置。
- 私有驱动（`patches/vendor-display/`）本体需上述运行时数据，序列静态部分已交付
  （`research/full-disasm/reg_init_sequence.md`）。在 L0 确认前不投入完整驱动。
