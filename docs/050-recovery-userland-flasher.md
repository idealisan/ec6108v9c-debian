# 050 — 改造原厂 recovery 用户态：自动刷机 + 显示程序（第一阶段产物）

> 2026-11-08。用户最终方向：**用原厂 recovery 内核、改造其用户态程序**，做成
> 「短接刷机态上电自动执行刷机任务、零菜单/零交互、并在 HDMI 显示进度条」的程序
> （设备无按键、无串口）。目标语：「再次阅读 REA 技能、反编译研究 recovery / LK2nd、
> 做出能显示的引导和刷机程序」。本文记录落地产物、证据与待验证项。
>
> 方法：`TMP/rea/.agents/skills/reverse-engineer-anything/SKILL.md`（三分法、证据优先、
> 目标路由、finding ledger、不靠文件名/布局推断行为、独立 oracle 互验）。
> 相关：`docs/023`（recovery 显示机制，但其内核版本结论被本轮修正）、`docs/035`（recovery
> vmlinux MMIO）、`docs/036`（刷机执行者）、`docs/038`（BootROM USB_BOOT）、`docs/040`（在线写 fb0）、
> `docs/048`（SDK 绘制链路）、`docs/049`（裸机 display.bin 探针，本路线的前一版）。

---

> **真机更新 2026-11-08（决定性，见 §8）**：短接触点 + `--verify` 未改镜像 →
> **成功进入原厂 recovery、点亮背光、显示 `warning, no file contacts`**，随后自动重启回社区 Ubuntu。
> → **短接态内核能从零点亮 HDMI、`/dev/graphics/fb0` 可用，整条改造路线成立**（§6 决定性未知① 已定案）。
> 未看到进度条是预期内：那次跑的是原厂 `/sbin/recovery`（未改镜像），不是我们的 `flasher`。
>
> **真机更新 2（第 2 步 PASS，见 §8.5）**：换改造版 `recovery.img` 短接启动 → 用户确认
> **看到了彩色进度条画面、符合预期**。→ 自定义用户态被 init 拉起、`fb0` 写入生效、显示目标达成。
> 两阶段 go/no-go 全部通过；此后转入刷机程序迭代（§10 阶段计划）。

---

## 0. 结论先行

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| 1 | **改造原厂 recovery 可行吗？** | **可行，且原料/工具链本机齐备**。保留原厂 3.10 内核（自带 hifb/VO/HDMI 驱动，负责点亮 HDMI + 注册 `/dev/graphics/fb0`），只替换 ramdisk 里 `sbin/recovery` 一个用户态文件。 | [观察] |
| 2 | **为何比"裸机从零点亮 HDMI"靠谱？** | 裸机 `go` 后无内核/时钟框架；成员查实 CRG/PLL/`G0_ADDR` 多为运行时 RMW/动态地址（`docs/035`），静态直写几乎不可能一次成。复用内核则显示栈现成，用户态只需 `open(fb0)`+写像素（`docs/040` 实证）。 | [观察]+[推断] |
| 3 | **短接态怎么加载？** | 社区 `fastboot.bin` 的 `bootm` **直接 boot Android boot.img**：`check_header` 仅 memcmp 8 字节 `ANDROID!`，`get_ramdisk` 反汇编实证把 ramdisk `memcpy` 到 `0x04e00000` 并作 initrd。故 `bootcmd=fatload usb 0 0x1000000 recovery.img; bootm 0x1000000`。无需转 uImage/DTB/单独 ramdisk。 | [观察]（成员反汇编） |
| 4 | **零交互自动执行？** | `init.rc` 已有 `service recovery /sbin/recovery` + `on early-init start ueventd` + `on boot class_start default`，上电自动拉起；替换后的程序无菜单、无按键依赖。 | [观察] |
| 5 | **刷机动作？** | 程序挂载 U 盘到 `/usb`（`recovery.fstab` 有 `/dev/block/sda1 → /usb`），若存在 `/usb/flash.manifest` 则按行 `<src> <LBA-hex> <bytes-hex>` 把镜像按**绝对 LBA 裸写** `/dev/block/mmcblk0`，逐项推进进度条；无 manifest 则纯显示、**零 eMMC 写入**。 | [观察]+[推断] |
| 6 | **真机显示已证实？** | **部分证实**：短接态内核点亮 HDMI、显示原厂 recovery UI（§8 第 1 步 PASS）。但**自定义 flasher 的进度条尚未在真机出现**——那次刷的是未改验证镜像。第 2 步（改造版）已装上 U 盘，待下一次刷机验证。 | [观察]+[未知] |

---

## 1. 为什么换路线（REA 硬证据）

用户原直觉「原厂 recovery 能显示、软件小、反编译会有帮助」被证实，但 **recovery 不是"小程序"**：
它是 16 MiB Android boot.img = 2.56 MB **3.10 内核**（含整套私有显示栈）+ 0.96 MB ramdisk
（`/sbin/recovery` 458 KB 静态 ELF + PNG 字模/进度条）。显示由**内核驱动**完成，`/sbin/recovery`
自己不碰寄存器，只 `open("/dev/graphics/fb0")` + `FBIOGET_*SCREENINFO` + blit PNG（`docs/023 §3`）。

对比 `docs/049` 的裸机 `display.bin`：`go` 之后是 pure bare-metal，要"从零点亮 HDMI"等于用汇编
重实现整个内核显示初始化链；成员本轮查实 `CRG + PLL + G0_ADDR` 多为 RMW/动态值、无静态序列，
且 `do_go` 不关 MMU/D-cache（`docs/037`），物理 MMIO 可达性未定 → **裸机路线几乎不可能一次成功**。
真机反馈（刷机态全黑、连背光都不亮、卡黑屏很久）也与此一致：短接分支根本没点 HDMI。

→ 正解是**复用一个已把显示栈跑起来的内核**。这正是 LK2nd 类二级引导的价值，但：

## 2. LK2nd 调研（结论：不适用）

- `lk2nd`（postmarketOS / CodeAurora Little Kernel 分支）**仅支持高通 MSM SoC**
  （msm8916/8974/8226/8952/8953/8960 等），打包成 Android boot image 由高通原厂 aboot 加载。
  Hi3798MV100 / EC6108V9C 不在任何支持列表，启动链也不同（HiSilicon BootROM → `fastboot.bin`）。
- 依赖 **Volume Down 进 fastboot / Volume Up 进 recovery** 按键交互；本机无按键、无串口。
  即便移植也要重写整套交互 → 成本≈重写，用户判断「即便有也要大改」正确。
- 更贴近的现成件：`histb-mainline/histb-stage1`（HiSTB fastboot→TF-A 一阶段）、`hiloot`（串口引导）、
  主线 7.3 内核（社区称 EC6108V9C HDMI 可用）。本路线不依赖它们。

## 3. 产物与文件（仓库内相对路径）

| 文件 | 作用 |
|---|---|
| `recovery-flasher/stock/recovery-stock.img` | **入库的原厂 recovery boot.img**（3.5 MiB，含无源码的 3.10 内核），方案必需输入，见 `stock/README.md` |
| `recovery-flasher/flasher.c` | freestanding ARM Linux 静态程序：自动拉起、`fb0` 进度条、manifest 自动刷机、常驻不退出 |
| `recovery-flasher/repack.py` | 读 `stock/recovery-stock.img`、cpio newc 手术替换 `sbin/recovery`、重打包、产出验证/改造两镜像 |
| `recovery-flasher/build.sh` | 一键：编译 flasher → repack → 生成 `bootargs.bin` → 组装 U 盘三件套（可 `--verify` / `--install`） |
| `TMP/recovery-flash-out/` | 构建产物（gitignored）：`flasher`/`recovery.img`/`recovery-verify.img`/`recovery-flash-boot.img`/`bootargs.bin`/`README.txt` |

**工具链 / 架构（32 位，与原厂对齐）**：本机
`clang --target=armv7-unknown-linux-gnueabi -fuse-ld=lld -static -nostdlib
-fno-vectorize -fno-slp-vectorize -mfloat-abi=soft`
产出 **ELF32 / 小端 / `e_machine=0x28`(ARM，非 AArch64) / EABI5** 静态 EXEC——与原厂
`/sbin/recovery` 的属性逐项一致（原厂：`ELF 32-bit LSB ARM EABI5 static`）。Hi3798MV100 是
ARMv7-A 32 位，用户态程序必须 32 位 ARM。freestanding syscall 直发 `svc #0`，自制
`__aeabi_uidiv`（无 libgcc）。无需交叉 gcc / libc / sysroot / CI，全量重建 < 1 s。

**架构修正（重要）**：初版用 `gnueabi**hf**` + `-O2` 时，clang 把显存填充循环自动向量化，
产物混入 43 条 NEON 指令（`vld1.32`/`vst1.8`/`vmov`…）。recovery 的 3.10 内核在早期用户态
未必使能 VFP/NEON（CP10/CP11），一条 NEON 就可能触发未定义指令异常 → 程序崩、屏幕全黑。
故改为 **soft-float + 禁自动向量化**，反汇编复核 **NEON/VFP = 0 条、纯整数 ARM 592 条**，
`e_flags` 置 soft-float 位（0x05000200）。这是"32 位"之外必须核对的指令集兼容性。

## 4. 精确结构与校验（[观察]，均实测）

- 原厂备份 `TMP/stock-rom-research/extracted/p03_recovery.img`(16 MiB)：首 8 MiB 是计数器填充，
  **`ANDROID!` boot.img 头 @ 偏移 `0x800000`**（非 0）。
- boot.img v0 头：kernel 2,563,176 B @`0x3e08000`、ramdisk 957,395 B @`0x4e00000`、
  second 0、tags `0x3e00100`、page 2048、cmdline 含 Android 16 分区 `blkdevparts=`。
- kernel blob（`@+0x800`）是 legacy uImage（`0x27051956`，`Linux-3.10.0_s40`，load=ep `0x2000000`）
  —— **修正 `docs/023 §4.1` 说的 4.4**：那份 4.4 是社区 `hi_kernel.bin`，原厂 recovery 是 3.10。
- ramdisk = gzip(1f8b08) → newc cpio(070701)，53 项，含 `sbin/recovery`(445,036 B 静态 ELF)、
  `init.rc`、`ueventd.rc`、`res/images/*.png`。注意 `TMP/rec-kernel.bin.ramdisk` 是**另一份**
  （docs/023 对象，458,568 B）的 ramdisk，勿混用。
- 提交前硬校验全过：内核逐字节未改（sha `f49aab1b…`）；重建 boot.img `ramdisk_size` 与新 gz
  一致、ramdisk 偏移 `0x272800` 与文件长度自洽；cpio 53 项 + `TRAILER!!!` 完整；替换进去的
  `sbin/recovery` 字节等于编译产物 flasher；`bootargs.bin` CRC32 头重算匹配。

**隐私/合规**：源码/脚本/文档/commit 无本机绝对路径/IP/用户名/凭据；构建产物在 `TMP/`（gitignored）；
不删文件、不用 `rm`/`git clean`；显式 `git add <具体路径>`；`--install` 先备份 U 盘原 `bootargs.bin`。
**例外（用户 2026-11-08 明确决定）**：原厂 recovery boot.img（含 3.10 内核 blob）作为**方案必需且
无源码**的输入，已裁成独立 `recovery-flasher/stock/recovery-stock.img`(3.5 MiB) **入库**，
见 `stock/README.md`（SHA-256、来源、合法性说明）。此前"内核未入 git"的表述作废。
`repack.py` 现优先读仓库内这份（头在偏移 0），magic 扫描自适应 16 MiB 分区版（头在 `0x800000`），
因此 clone 仓库即可复现，不依赖本机备份。

## 5. 两段式 go/no-go（用户操作，决定性）

**第 1 步已于 2026-11-08 通过（§8）**：短接态内核点亮 HDMI、显示原厂 recovery UI。
曾担心"短接态内核是否从零点亮 HDMI"（社区 4.4 似只继承 hiboot 的 VO 状态），现已定案 =
**是**。故直接进入第 2 步。

1. ~~**第 1 步（验证内核）**~~ **已完成 ✅**：`--verify` 未改镜像 → 出现原厂 recovery
   `warning, no file contacts` 界面 → 内核在刷机态点亮 HDMI、fb0 可用 → 本路线成立。
2. **第 2 步（改造版，已装上 U 盘，待验证）**：`bash recovery-flasher/build.sh --install <U盘目录>`
   （默认 MODE=flash，替换 `sbin/recovery`）→ 短接上电，应看到**自绘进度条**；放
   `/usb/flash.manifest` 则自动刷机。U 盘当前 `recovery.img` 已切成改造版
   （sha256 `45aab097…`）。

## 6. 仍未定案（[未知]，真机才能定）

1. ~~**决定性**：短接态 3.10 内核是否独立初始化 HDMI/VO~~ **已定案=是（§8，2026-11-08）**：
   短接态内核点亮背光、显示原厂 recovery UI。剩余未知是「自定义 flasher 是否真被拉起并显示进度条」。
2. `bootm` 的 `initrd=`/`root=` 精确合并方式、社区 `bootargs` env 与 boot.img cmdline 的
   `blkdevparts` 冲突（16 分区 vs 当前 eMMC 9 分区）是否影响——按绝对 LBA 裸写可绕开，但内核
   启动阶段 `cmdlinepart` 建立 by-name 节点的具体表现未验证。
3. `ueventd` 是否在刷机态创建 `/dev/graphics/fb0`；fb0 几何/双缓冲是否如 `docs/040`。
4. 无 `Secure boot` 签名校验（成员 [推断] 未实证）——若校验开启，`bootm` 会拒改过的 boot.img。
5. `flash.manifest` 的目标 LBA 需按当前分区布局确定；第一版无 manifest = 零写入、纯显示验证。

## 7. 与总目标的关系

本产物是「引导/刷机阶段显示可见性」的**新主线**：复用原厂 recovery 内核 + 自包含自动刷机
用户态程序，零交互、带进度条。相较 `docs/049` 裸机探针，绕开了 HDMI 初始化难题。
所有后续迭代（真实刷机 LBA、进度条细化、字体/文字）都局限在 `flasher.c` / ramdisk 用户态，
内核与 p1/fastboot 一律不动，盒子始终可经同一短接流程重刷。

---

## 8. 真机验证记录（2026-11-08，用户实测）

### 8.1 第 1 步（未改 `--verify` 镜像）— PASS

| 项 | 观察 | 标注 |
|---|---|---|
| 引导方式 | 短接 USB_BOOT 触点 + U 盘 | [观察] |
| 现象 | **成功进入 recovery、点亮背光**；过一段时间显示 `warning, no file contacts` | [观察] |
| 以往对照 | 该画面**以往只在遥控器方式进入 recovery 时出现**；这次用短接刷机方式也出现 | [观察] |
| 之后 | 过一段时间**自动重启，进入普通社区 Ubuntu**（正常开机） | [观察] |
| 进度条 | **未出现**任何自定义进度条/迹象 | [观察] |

`no file contacts`（应为 `no file context` / 无刷机命令之意）是**原厂 `/sbin/recovery`
找不到刷机包/命令时的自绘界面**——因为这次 `recovery.img` 是 `--verify` 的**未改镜像**，
跑的是原厂程序，不是我们的 `flasher`。所以"没有进度条"是设计内、预期内，不是失败。

### 8.2 由真机结果得到的定案

- **[观察→结论] 短接态内核能从零点亮 HDMI**：背光亮 + 原厂 recovery UI 显示，证明
  原厂 3.10 内核在短接刷机分支**独立初始化了 VO/HDMI 并注册了可用的 framebuffer**，
  不依赖 hiboot 正常开机的 logo 状态。这是此前最大未知（§6 ①）的答案，**改造路线成立**。
  显示链路可用 → `/dev/graphics/fb0` 存在 → 我们 `flasher.c` 的 `open(fb0)+mmap+写像素`
  前提成立（具体几何/双缓冲仍需第 2 步验证，§6 ③）。
- **[观察] 引导链完全打通**：短接 → BootROM 加载 `fastboot.bin` → `bootargs.bin` 的
  `bootcmd=fatload ... recovery.img; bootm 0x1000000` → `bootm` 直起 Android boot.img →
  内核 + ramdisk → `init.rc` 拉起 `service recovery`。无按键、无串口、零交互，符合目标。
- **[观察] 自动重启**：原厂 recovery 无命令后的正常退出/看门狗重启，回到社区 Ubuntu。
  我们的 `flasher` 是常驻死循环（`for(;;)` 不退出），**不会走这个自动重启**——若第 2 步
  出现"进度条一闪又重启"，需排查看门狗/内核 panic，而不是把它当成成功。
- **[推断] 未改镜像能显示 ≠ 改造镜像能显示**：`bootm` 对改过的 boot.img 若有签名校验会
  拒绝（§6 ④ 未证实）；且我们的 `flasher` 是否真被 init 拉起、`fb0` 写入是否生效，都要
  第 2 步真机看。**这是当前唯一待验证的决定性未知。**

### 8.3 已就位的第 2 步

U 盘已插回，`recovery.img` 已切成**改造版**（sha256 `45aab097…`，ramdisk 内
`sbin/recovery` = 禁 NEON 的 `flasher`，内核逐字节未改）。下一次短接上电应看到自绘
进度条。判定：

| 第 2 步现象 | 结论 / 下一步 |
|---|---|
| **持续增长/循环的彩色进度条** | 自定义用户态跑通、fb0 写入生效 → 显示目标达成；随后接 `flash.manifest` 做自动刷机 |
| 仍是 `warning, no file contacts` 原厂界面 | 改造镜像没被加载（`bootm` 拒绝改过的 img / 或拿了错的 `recovery.img`）→ 查签名校验 §6 ④、确认 U 盘文件名 |
| 全黑 / 一闪即重启 | `flasher` 崩溃或看门狗 → 用 `recovery-verify.img` 复核，排查 fb0 打开、`svc`、init 拉起 |
| 花屏/局部色条 | fb0 几何不对（stride/双缓冲）→ 按 `docs/040` 调 `fb_init()` |

### 8.4 关于"自动执行刷机任务、无菜单"

`flasher` 天生零交互：`init.rc` 的 `service recovery` 自动 exec，程序一进入就执行
`auto_flash()`——挂载 U 盘到 `/usb`、若有 `flash.manifest` 就按 LBA 裸写 eMMC 并推进进度条，
无 manifest 则纯显示（安全）。**没有菜单、不等待任何输入**。真实刷机的目标 LBA 需按当前
eMMC 分区布局确定（§6 ⑤），属显示验证通过后的下一迭代。

---

## 9. 后续能力判定：TTY→HDMI 与 U 盘日志（kallsyms 实证）

用户 2026-11-08 两问：① 能否把 TTY 绑到 HDMI 显示日志文字（不行则用颜色进度条）；
② 既然原厂 recovery 是 Linux，能否写日志文件到 U 盘（可选）。
用 `TMP/recovery-deep/kallsyms-symbols.json`（recovery 3.10 vmlinux，重建 35,937 符号）
逐组包含匹配判定，REA 三分法：

| 能力 | 符号命中 | 结论 | 标注 |
|---|---|---|---|
| **fbcon / framebuffer console**（`fbcon_*`/`bitblit`/`softcursor`） | **0** | 内核未编 `CONFIG_FRAMEBUFFER_CONSOLE` | [观察] |
| **VT / 虚拟终端**（`vt_console`/`vc_allocate`/`do_con_write`/`redraw_screen`） | **0** | 无 VT 层 | [观察] |
| **字体**（`font_*`/`vgacon`/`fbcon_set_font`） | **0** | 无 console 字体 | [观察] |
| fbdev 核心（`register_framebuffer`/`framebuffer_alloc`/`fb_set_var`） | 22 | 有 `/dev/graphics/fb0`（进度条已用） | [观察] |
| console 通用（`register_console`/`console_drivers`） | 9 | 仅串口 `ttyAMA0` console | [观察] |
| printk / kmsg（`printk`/`kmsg_fops`/`log_buf`） | 137 | 内核日志在内存，但无 fbcon 输出到屏 | [观察] |
| **vfat / fat**（`fat_*`/`vfat`/`msdos`） | 189 | 内核自带 FAT 文件系统 | [观察] |
| **usb-storage**（`usb_stor_*`） | 92 | 内核自带 U 盘驱动；`recovery.fstab` 有 `/dev/block/sda1 → /usb` | [观察] |

**结论 ①（TTY→HDMI）：不可行（[推断]，基于 0 命中）**。把 `console=tty0` 的文字画到 HDMI
需要 fbcon + VT + 字体三者，这颗内核全部缺失，且**无源码无法重编加入**。用户判断正确：
**继续用自绘颜色进度条**显示进度；要"日志文字"只能由 `flasher` 自己用位图字体 blit 到 fb0
（等价于进度条的像素绘制，非内核 TTY）。

**结论 ②（U 盘日志）：可行（[观察]）**。内核自带 vfat + usb-storage，`fstab` 也声明了 U 盘挂载点。
`flasher` 作为 Linux 用户态可在 `mount("/dev/block/sda1","/usb","vfat")` 后
`open/write/fsync` 写 `/usb/flasher.log`。这补上了用户早先"程序写文件到 U 盘记录运行到哪"的诉求
（当时裸机 `display.bin` 无 FAT 栈做不到，如今 Linux 用户态天然可行），并作为**不依赖 HDMI/串口的
等价验证通道**纳入阶段 0：每完成一步写一行日志，拔盘插回电脑即可读。

（阶段 0/1/2 的完整刷机计划见用户确认的计划：`docs/050 §8` 之后的下一迭代，本节仅记录能力判定。）

### 8.5 第 2 步（改造版）真机结果 — PASS

用户 2026-11-08 换改造版 `recovery.img` 短接启动后确认：**看到了彩色画面（进度条），符合预期描述**。
→ [观察] 改造 boot.img 被 `bootm` 接受（无签名拦截，§6 ④ 的担忧排除）、`init.rc` 拉起替换后的
`sbin/recovery`(=flasher)、`fb0` 写入生效。**两阶段 go/no-go 全部通过**：短接态内核点亮 HDMI ✓、
自定义用户态自动运行并显示 ✓。显示目标达成，转入刷机程序迭代。

---

## 10. 刷机程序迭代计划（用户已确认）

**已定决策**：① 不研究 LK2nd（对本芯片不适用）；② 第一版刷机目标 = **社区 Ubuntu 包**
（已知能启动，专门验证"刷写链路"，与"Debian 能否启动"分离）；③ 刷完**停在完成画面、不重启**。

| 阶段 | 内容 | 判据 |
|---|---|---|
| **0（本次，已装盘）** | `flasher.c` 加 U 盘日志 + 环境探测，**ZERO eMMC 写入**；保留已验证的进度条 | 拔盘插回电脑读到 `/usb/flasher.log` |
| 1 | 定镜像/LBA；把社区 rootfs 的 Android sparse 还原成 raw（裸写 LBA 不认 sparse） | 镜像/LBA 清单可复现 |
| 2 | 真正无人值守刷 `flash.manifest` 全部条目 → 进度条走满 → 停在完成画面 | 日志显示每步写入字节数；断电重启进社区 Ubuntu |

### 10.1 阶段 0 落地（本次提交）

`flasher.c` 以 `#define STAGE 0` 编译，进入 `probe()`（不调用 `auto_flash()`）：

- 保留 `fb_init()` + 已验证的进度条动画（用户仍应看到熟悉的彩色条）；
- `udisk_mount()`：`mkdir /usb` 后按 6 个候选 `(dev, fstype)` 尝试 `mount`（两轮、间插 delay
  等 ueventd 建节点）——覆盖 `/dev/block/sda1`、`/dev/sda1`、`vfat`/`msdos` 等；
- 写 `/usb/flasher.log`，逐行 `log_kv()` 记录：fb0 open/mmap/smem_len/stride/rows×cols、
  mkdir 结果、6 个 mount 的返回码、`/usb/recovery.img` 是否可读（前 4 字节）、
  `/dev/block/mmcblk0` 与 `/dev/mmcblk0` 是否可 `O_RDWR` 打开（**只 open 随即 close，零字节写**）、
  by-name 分区节点、`/usb/flash.manifest` 是否存在（阶段 0 忽略）、显式 `eMMC WRITES: NONE`；
- `fsync` 日志 + `sync()` 刷 FAT 元数据，确保拔盘不丢。

**编译/校验（[观察]）**：ELF32 ARM EABI5 静态、6488 B、NEON/VFP=0、35 个 svc 调用点、
soft-float；ramdisk 内 `sbin/recovery` 字节 == 新 flasher、内核逐字节未改；`bootargs.bin` CRC 重算匹配。
产物装 U 盘 `recovery.img`（sha256 `8639a7cc…`），`bootcmd` 不变。

**待用户操作**：短接上电 → 应看到熟悉的彩色进度条 → 断电拔盘插回电脑 → 读 `/usb/flasher.log`
并发回内容。日志回答三个未定案项：U 盘能否挂载、`mmcblk0` 节点是否存在、`sda1` 命名是否正确——
据此进阶段 1。**阶段 0 不碰 eMMC，绝对安全。**
