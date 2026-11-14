# 053 — 主线 6.x 刷机包真机验证 SOP（一次性给出可判定信号）

> 2026-11-09 制定，2026-11-14 更新真机进度。配合 U 盘 `README-VERIFY.txt`。目标包：6.3
> 主线内核 + Debian rootfs，recovery-flasher 方式刷入（p2/p5/p6/p8 绝对 LBA，p1 fastboot
> 永不写）。本文的目的：把「能引导 / 能显示 TTY / 能连网」三个目标拆成**互相独立、
> 可分别观测**的判据，让你一次刷机就能告诉我卡在哪一级，我据此进入下一轮修改，不再盲试。

## 真机进度（2026-11-14，刷 vendor-backport 包 `build-20261114T035227Z`）

- **L0 绿带 = 已确认**：刷机成功、断电重启后，`Debian Linux` logo 之上出现一大片绿色横条。
  这是 vendor 显示驱动 `hi3798mv100_vendor_display.c` 的 `vd_paint_boot_marker` 在
  `subsys_initcall` 画的（顶部 240 行 × stride）。它一次性坐实：
  1. **主线 6.3 内核确实启动了**，并跑到显示驱动 initcall（UNKNOWNS 优先级 0 结案）；
  2. §D 定死的 `+0x6010` 读到了真实有效的交接显存地址（`vd_valid_fb_addr` 通过才画，
     否则 `-ENODEV`），`+0x494` 压缩视图作废；
  3. 显存可写、VO/HDMI 管线活着、交接地址本次有效。
- **L1 TTY 文字 = 无；L2 新 IP = 无**。绿带在 initcall level 4（很早），之后才轮到
  simplefb probe→fbcon→TTY、MMC→root 挂载→userspace→网络。两个都没有 → 内核停在
  level 4 之后到 userspace 之间；已静态排除 clock/mmc/format/字体 等确定性缺配置。
- **本轮改动 = 新增自绘 framebuffer console**：拿日志的常规通道（串口/TTY/IP/pstore）
  全断，但绿带证明显存可写 + VO 在扫描，于是用 `font_vga_8x16` 把 printk 直接画到
  交接显存（绿带下方文本区），`CON_PRINTBUFFER` 回放开机全量日志 + 之后实时输出。
  **下一版刷机，绿带下方应出现启动日志文字；屏幕停在最后一行 = 内核卡点。**
  `boot_console=0` 可关。详见 `patches/vendor-display/PORTING.md` 状态段。
- **下一版回报重点**：绿带下方是否有文字？屏幕最后几行写的是什么？（能直接定位
  `rootwait` / 某 initcall panic / MMC probe defer / 到没到 userspace）。L2 仍看路由器新 IP。

### 真机第 2 轮（2026-11-14，刷含自绘 console 的包 `build-20261114T060735Z`）

- **L1 文字确实出现了**（自绘 console 成功，`CON_PRINTBUFFER` 回放生效）——这是拿日志
  通道被打通的里程碑。但暴露两个**显示层 bug**（非启动 bug）：
  1. **整个画面 45° 像素级斜切**，文字像斜体/斜切一样难认。根因已定位：写入显存的
     行步长 ≠ VO 硬件扫描行步长。`G0_STRIDE` 寄存器存的是 `pitch/16`（SDK
     `drv_hifb_hal.c:39 STRIDE_ALIGN 16`、`:616 GetLayerStride=surface_stride*16`），旧
     驱动却把寄存器原值当字节 pitch、又用 `width*4` 猜，行寻址每行相对上一行横移 →
     斜切。绿带看着正常只因它是**线性连续填充**（不按行寻址），恰好掩盖了此 bug。
  2. **像素随时间被噪点慢慢侵蚀**：最可能是**交接显存页没从内核页分配器保留**
     （docs/053 §6 早已预判）——主线 DTB `/memory@0` 覆盖全 1GB、只有
     `ramoops@0x30000000` 是 no-map，hiboot logo buffer 落在高端可用 RAM 里，内核
     buddy 随运行逐渐把这些页分配/写脏 → 画面被噪点「侵蚀」。另一候选：VO 双缓冲
     （`G0_NADDR` 未写第二帧）翻页露出旧帧。当时**误排除**「WB cache 一致性」——
     理由「静默卡住时无 CPU 写显存」不成立（每来一条新 printk 就有 CPU 写）。
     `memremap()` 对 System RAM 拒绝非 WB flag（`kernel/iomem.c:106`）这点仍成立，
     所以修法不是改 WC，而是**显式 clean d-cache**（真机第 3 轮已证伪并修正，见下）。
- **卡点定位（重要）**：屏幕停在 `random: crng init done`（`random.c:726`，
  `_credit_init_bits()` 熵池达 `POOL_READY_BITS` 时 pr_notice），之后等了约 700 秒都
  无新日志，直到拔 U 盘才出现 `usb disconnect`。这说明**内核没死**——中断、printk、
  console 全活着；是**静默卡死**在 `crng init done` 之后。它属**内核启动阶段**
  （熵攒够时打印，通常在 initcalls 期间或之后），确定**还没进 userspace**——之后本该
  依次出现 `Freeing unused kernel memory` → `Run /sbin/init as init process` → systemd
  → DHCP/新 IP，`一条都没有` → 卡在 initcalls 后期到挂载 root 之间。cmdline 带
  `rootwait`，头号嫌疑是无限等 `mmcblk0p8`（MMC 没认出分区 / probe defer）或某
  initcall 自旋。**下版判据**：若倾斜修好、文字能认，看 `crng init done` 之后有没有
  `Waiting for root device ...`（`do_mounts.c:636`，rootwait 触发时必打）——有=卡在等
  根设备，可查 MMC/分区；没有=卡在更早的某个 initcall。
- **本轮修复（均在 vendor 驱动一个文件内，零引导链/DTB/cmdline 改动）**：
  - **主修 45° 斜切**：写入行步长严格 = VO 硬件扫描行步长（`G0_STRIDE*16`，
    SDK `drv_hifb_hal.c:39/:616` 依据；两编码自适应 + `con_stride` cmdline 逃生舱），
    `width=stride/4` 让 putc/scroll/clear/simplefb 全部按同一 pitch 行寻址 → 消除斜切。
    旧代码把寄存器原值（=pitch/16）当字节用、又用 `width*4` 猜，是斜切根因。
  - **侵蚀本轮不动 DTB**（避免破坏已能引导的状态），改为**加诊断、等真机数值**：
    `pr_info` 打印 `addr` / `stride_raw` / 换算 pitch / `ireso` / `naddr` / 几何 / force，
    随开机日志回放显示在屏幕上。下一版据此二选一精确修：
    - 若 `naddr` 与 `addr` 相差一帧 → 双缓冲，需把绿带+文字也写进第二帧；
    - 否则 → 显存页复用，在 DTB 加 `reserved-memory/no-map` 把这段高端 RAM 从
      `mem=1G` 里挖出来（地址由本次 `addr` 真值确定，不写死猜地址）。
  - 保持 `MEMREMAP_WB`（System RAM 只能用 WB，见上）；绿带 L0 与 console 不受影响。
  - 若下次仍斜，回报屏幕 `VO layer0: ... stride_raw=... pitch=...` 数值，或用
    `hi3798mv100_vendor_display.con_stride=<bytes>` 直接指定，无需重编译。

### 真机第 3 轮（2026-11-14，刷含 45° 斜切修复的包 `build-20261114T133008Z`）

- **斜切修复生效**：文字终于能读出具体字符串（上版"难以辨认"），因此拿到了
  十几轮以来第一批**可读的完整内核日志**。
- **日志里看到的（经源码核对，全部非致命）**：EMMC 检测成功、USB 枚举成功；
  `direct firmware load for rtlwifi/rtl8188fufw.bin failed with error -2` +
  `RTL8xxxu: Probe of 3-2:1.0 failed with error -11`（USB WiFi 缺固件；`-11=-EAGAIN`
  是 `rtl8xxxu_load_firmware()` 里同步 `request_firmware()` 失败的返回值）；
  `cfg80211: failed to load regulatory.db`（`reg.c:1008` 的 `pr_info`，无线监管库，
  内核回退内置 world domain）；`clk: Not disabling unused clocks`
  （`clk.c:1405` 的 `pr_warn`，是 `clk_ignore_unused` 生效的**正常提示**）；
  4 个 `amba f8aXXXXX.timer deferred probe pending`（`dd.c:316`，
  `deferred_probe_timeout` 到期时的汇总打印，内核已继续）。
- **卡在 `random: crng init done` 之后、无任何新日志**；等约 700 秒拔插 U 盘才刷出
  `usb disconnect` → 内核活着、中断/printk/console 全活，是**静默卡死**。

**决定性根因（静态钉死，非猜测）**：`root=mmcblk0p8` **缺 `/dev/` 前缀**。
`name_to_dev_t()`（`do_mounts.c:277`）把它交给 `devt_from_devnum()`，后者按
**16 进制**解析、遇第一个 `m` 即 `return 0` → `ROOT_DEV` 永远为 0。于是
`prepare_namespace()` 的 `rootwait` 分支（`do_mounts.c:635`）
`while (driver_probe_done()!=0 || (ROOT_DEV = name_to_dev_t(...))==0) msleep(5);`
每 5ms 静默空转、**一条 printk 都不打** —— 精确解释"内核活着但无声卡住、无 IP"。
且 `driver_probe_done()` 查的是活跃 `probe_count`，不是 deferred pending 列表，
所以那 4 个 pending 设备不是主因。

- **修法**：`root=/dev/mmcblk0p8`（走 `devt_from_devname()` → `blk_lookup_devt()`
  拿到真实分区 dev_t，挂载成功即进 userspace 出 IP），并把 `rootwait` 换成
  `rootdelay=5`：若 root 仍缺失，则让 `mount_root()` 明确打印
  `VFS: Cannot open root device` + `here are the available partitions` 分区列表
  + panic，一次刷机即可定位。p2 runtime env 的 `bootargs` 与 DTB `/chosen/bootargs`
  同源（`configs/partition-layout.env`），两处同时生效。
- **"新日志破碎、老日志稳定、拔插 USB 刷新后能看清" = WB cache 一致性**（修正第 2 轮
  误判）：CPU 写像素滞留在 D-cache 未回写 DDR，VO DMA 读到旧数据；后续写入推动
  cache line 淘汰回写，老行才稳定。修法：console 写完像素后按本次触及的字节范围
  显式 `__cpuc_flush_dcache_area()` clean（`asm/cacheflush.h`），保持 `MEMREMAP_WB`
  （改 WC 会让 `memremap` 对 System RAM 返回 NULL、连绿带都丢）。
- **WiFi 固件顺手修好**：主线 `rtl8xxxu` 本身就是开源驱动（社区 4.4 用的是
  out-of-tree vendor `rtl8188fu.ko`，不能用于 6.3），只缺 blob。本启动链**无
  initramfs**，initcall 阶段读不到 rootfs 的 `/lib/firmware`；且 Debian
  `firmware-realtek` 只含 8188e/8188eu、不含 8188fu。故取 linux-firmware 上游
  `rtlwifi/rtl8188fufw.bin`（21,020 B，signature `0x88f1`→`0x88f0` 命中
  `rtl8xxxu_load_firmware()` 白名单），用 `CONFIG_EXTRA_FIRMWARE` **编进 vmlinux**，
  `EXTRA_FIRMWARE_DIR` 由 `build-kernel.sh` 在构建时设为绝对路径（不写进仓库文件）。
  `regulatory.db` 仍会报缺失（非致命，用内置 world regulatory domain）。
- **下一版回报重点**：① 文字是否**不再破碎**；② `crng init done` 之后是否出现
  `Freeing unused kernel memory` / `Run /sbin/init`（有 = 进 userspace），或
  `VFS: Cannot open root device` + 分区列表（有 = 贴出分区列表）；③ 路由器有没有
  新 IP / SSH；④ 日志里还有没有 rtlwifi 固件报错（应消失）、有无 `wlan0`。

### 「原生 TTY」实验版（用户要求，2026-11-14 夜间，与上一版并存/可选）

用户觉得自绘 console「手动画字怪怪的」，要求做一版走内核标准链路的 TTY。
新增 `native_tty` 模块参数（默认 **1**）：
- `native_tty=1`：**标准 fbdev 路径** —— 用 `framebuffer_alloc + register_framebuffer`
  注册 `fb_info`，`console=tty0` 交给内核 `fbcon`/VT 渲染；`screen_base` 用已验证的
  `MEMREMAP_WB` 映射，`fbops` 包装 `cfb_*` 并 clean cache；不走 simplefb
  （它对 System RAM 用 `ioremap_wc` + aperture，是原生 fbcon 一直绑不上的嫌疑）。
  注册在 `device_initcall`，`fbcon=map:0` 保证 `do_fbcon_takeover` 触发。
- `native_tty=0`：完全回退到已验证的自绘 console（simplefb pdev + 绿带 + 日志回放）。

**这一版回报重点（原生）**：① 开机文字是否是**内核标准 TTY 字体/排版**（而非
自绘 8x16 小字）、绿带是否还是那一条；② `hi3798-vd: NATIVE fbdev fbN registered`
是否出现（fbdev 注册成功）、有没有 `fbcon: ...` 接管日志；③ 若黑屏无字，
说明 fbcon 没接管 —— 回报后我按 `native_tty=0` 或查 `register_framebuffer` 返回值处理；
④ 同样看 `root=/dev/...` 后是否进 userspace / 路由器新 IP。

## 0. 静态侧已排除的嫌疑（不用再查，节省时间）

- 内核源 = 6.3.0-rc5 主线（`third_party/linux-hi3798mv100`，Makefile VERSION=6/PATCHLEVEL=3，
  loonpn/ec6108v9c-linux-kernel），非 7.4-histb / 非 4.4-ecoo 下游内核。
- uImage magic/CRC 自洽，`load=entry=0x02000000` 与 hiboot
  `bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0` 对得上（0x1FFFFC0 + 0x40 header）。
- appended DTB 位于 payload 末尾、`totalsize` 合法；`/chosen/bootargs` 全项齐：
  `mem=1G`、`root=/dev/mmcblk0p8`（第 3 轮修复后带 `/dev/`，见上）、`rootdelay=5`
  （原 `rootwait` 因 `name_to_dev_t` 解析失败会静默死等，已换）、
  `console=tty0 console=ttyAMA0,115200`、`fbcon=map:0`、`blkdevparts`（8 分区）、
  `clk_ignore_unused`；`/memory@0 reg=<0x0 0x40000000>` 与 `mem=1G` 一致。
- `CONFIG_ARM_APPENDED_DTB=y` + `CONFIG_ARM_ATAG_DTB_COMPAT=y`（defconfig 自带，兼容 hiboot ATAG）。
- TTY 链配置齐：`CONFIG_VT/FRAMEBUFFER_CONSOLE/FONT_8x16/FB_SIMPLE=y` + `console=tty0` + `fbcon=map:0`。
- 网络链配置齐：`CONFIG_HISI_FEMAC/MDIO_HISI_FEMAC/PHYLIB=y` + rootfs `eth0` DHCP/systemd-networkd。
- 默认路径显示驱动 `hi3798mv100-hdmi-console.c` 的 VO G0 寄存器偏移已按 FINDINGS §D 修正为
  `+0x6010/0x601c/0x6020`、`ioremap 0xfff0`（旧 `+0x494` 是读 GP1_PARARD 的误算）。

**这些只证明"配置没明显错"，不证明内核真的执行到了。** 运行时是/否必须真机。

### 0.1 CI 编译日志实证（2026-11-09，run 42646761948 / release 161503Z）
从 build-kernel job 日志直接核对，三目标的**内核代码确实编进 uImage**（非仅 config 片段推断）：
- 引导：`Image Name: linux-hi3798mv100`、uImage 生成、无 `error:`/`undefined reference`；
  `cmdline:` 打印的 `/chosen/bootargs` 全项与 DTB 一致；`CC hi3798mv100_tsensor.o`。
- TTY：`CC drivers/video/fbdev/hi3798mv100-hdmi-console.o`（私有显示驱动）、
  `CC drivers/video/fbdev/core/fbcon.o`、`CC drivers/tty/vt/vt.o` + `consolemap.o` +
  `keyboard.o` + `vc_screen.o`（VT 全家桶）；`CONFIG_FRAMEBUFFER_CONSOLE=y`、
  片段 `CONFIG_VT=y`。→ `console=tty0`+`fbcon=map:0` 有真实绑定目标。
- 连网：`CONFIG_HISI_FEMAC=y`、`MDIO_HISI_FEMAC=y`、`PHY=y`、`NETDEVICES=y`。
- `verify key options` 段还打印 `CONFIG_FB_SIMPLE=y`、`CONFIG_COMMON_CLK_HI3798=y`、
  `CONFIG_RESET_HISI=y`、`CONFIG_EXT4_FS=y` 均为 `=y`，无符号被 olddefconfig 丢弃。

**即便如此**：代码编进内核 ≠ 内核跑到 userspace ≠ fbcon 绑上 framebuffer ≠ 网线协商成功。
这三条链每一环的"是否真的执行/绑定/连通"仍是运行时事件，只能真机 L0/L1/L2 判定。

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
**唯一可靠判据是屏幕**，请专注看 HDMI，别把时间花在 pstore 上：

- **绿带**：屏幕顶部出现纯绿粗带 = 内核跑到了显示驱动的 `subsys_initcall` = **L0 过**。
  （绿带是 L0 探针，不是最终显示方案；TTY 文字出现后会覆盖它。）
- **只有 `Debian Linux` logo + 浅蓝细线、全程无绿带无文字** = **L0 没过（内核极早期就挂）**。
- 中间态（有花屏/乱码、或先 logo 后黑屏）也请如实描述——它能区分"内核起来但显存被覆盖"
  与"内核没到显示 initcall"，见 §6。

> ⚠ **别用 pstore 当主判据（本刷机流程基本读不到，会白忙）**：
> ① ramoops 存在 DDR（`0x30000000`），**断电开机即丢**——L0 判定这一步必然经过断电；
> ② 优先级 0 最可能的情况正是内核在 pstore 初始化**之前**的极早期挂起，那时日志根本没写进去；
> ③ 刷主线包后 p8 已是 Debian rootfs，没有社区系统可 `ssh` 进去读 `/sys/fs/pstore`。
> 只有当内核**已经起到 pstore 子系统之后才 panic**、且是**不掉电的热重启**时 pstore 才有内容。
> 若你恰好在热重启后看到 `/sys/fs/pstore/dmesg-*`，贴出来有价值；否则直接以屏幕为准。

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
正常开机屏幕: (按时间顺序描述看到的每一帧: logo / 绿带 / 花屏 / 黑屏 / 文字)
L0 绿带: 有/无
L1 HDMI 启动文字/彩色条纹/login 提示符: 有/无(贴看到什么)
L2 路由器新 IP / SSH: 有/无
(可选) 若热重启后恰好有 /sys/fs/pstore/dmesg-*: 贴前几行; 没有就跳过
```

## 6. 仍待真机的 [未知]（不假装已定）
- VO `0xf8cc6010` 此刻的 MMIO 读值是否等于 `HIFB_DispBuf_HD`(≈0x3f6ce000)、跨次是否稳定。
- **显存保留隐患**：community fastboot 点亮 HDMI 后留下的 logo 帧缓冲（≈`0x3f6ce000`）
  在 6.3 DTB 里没有 `reserved-memory` no-map 保留，内核 `mem=1G` 可能把它当普通 RAM 覆盖 →
  VO 仍在扫描该区 → 花屏/乱码而非干净 TTY。该地址跨次稳定性 [未知]，故**不硬写进 DTB**
  （不编造地址）。真机若见花屏但 L0 已过，即指向此项：需在线态读 `/proc/msp/pdm` 的
  `HIFB_DispBuf_HD` 当次实际 PhyAddr、重启 2~3 次比对是否恒定，再决定 DTB no-map 保留还是
  运行时解析 `pdm_tag`（研究员 UNKNOWNS 优先级 2/4）。
- EDID / HPD / 显示时序（sink 运行时读）——私有驱动完整点亮 HDMI 序列的前置。
- 私有驱动（`patches/vendor-display/`）本体需上述运行时数据，序列静态部分已交付
  （`research/full-disasm/reg_init_sequence.md`）。在 L0 确认前不投入完整驱动。
