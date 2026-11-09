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

### 10.2 阶段 0 真机结果 + 阶段 1 合并迭代（用户反馈后改为数字编码）

**真机反馈（[观察]）**：换 stage0 版短接启动 → **又看到了彩色画面（进度条正常），但 U 盘里
没有出现 `flasher.log`**。→ 彩色画面正常 = `fb0`/自定义用户态照常工作；日志缺失 ⇒ [推断]
短接态 Linux 内核里 **U 盘未挂载成功**（短接时 `fatload` 用的是 hiboot 的 USB 栈，内核起来后
需重新枚举，`/dev/block/sda1` 节点或 vfat 挂载未就绪）。用户明确：**不要单独为日志再做一轮，
把它和下一步（刷机）合并推进**。

**关键改进：点阵数字状态码取代颜色编码（用户要求）**。理由：颜色无法精确口述（"除了极简单
几种颜色，其他说不准"），数字既简单又准确。用户不需要字母，**只要数字编码**。
`flasher.c` 重写为：`DIGITS[10][7]` 5×7 点阵字体，`show_number(n)` 放大居中画到两帧
（深色底 + 白色数字），`state(code)` 短显、`hold(code)` 永久停在最终数字（不重启）。

状态码（写进 U 盘 README）：`1` 启动/fb0 OK · `2` 挂载 U 盘 · `3` 挂载成功 ·
`4` 找到 manifest · `5` 刷写中 · `6` 完成 · `7` 挂载失败 · `8` 无 manifest(仅显示) ·
`9` eMMC 节点打不开。刷写过程显示增长的百分比数字 0..100（上升 = 正在写）。
**用户只需报出屏幕上的数字**，即可精确定位卡点。

**合并进同一版的阶段 1 刷机引擎**（不为日志单独迭代）：
- `flash.manifest` 每行 `<src> <lba-hex> <bytes-hex> <R|S>`；`R` 裸写、`S` 解 Android sparse。
- 查实社区包两个 `.ext4` 均为 **Android sparse**（magic `0xed26ff3a`，`recoverybox32`/
  `www_ecoo_top`），故裸写 LBA 前必须解码：`write_sparse()` 处理 28B 文件头 + 12B chunk 头，
  `RAW`(0xCAC1) 逐块写、`FILL`(0xCAC2) 展开、`DONT_CARE`(0xCAC3)/`CRC32` 用 `lseek` 跳过
  （不覆盖无关扇区）。`write_raw()` 处理非 sparse 项（fastboot/bootargs/logo/kernel/baseparam/pq）。
- 全部写入走原始 `/dev/block/mmcblk0` 绝对 LBA，绕开 16 分区 cmdline 与 9 分区 eMMC 的冲突。
- U 盘日志降级为 best-effort（能挂就写，不挂也有数字诊断）；`NO manifest => ZERO eMMC 写入`。
- 刷完 `hold(6)` 停在完成数字，不重启（用户选定）。

**U 盘 `mv100/` 现成可用**（[观察]）：社区全套镜像（`hi_kernel.bin`/`logo.img`/`bootargs.bin`/
`fastboot.bin`/`baseparam.img`/`pq_param.bin`/`recoverybox32.ext4`/`www_ecoo_top.ext4`），
社区刷机 env 的 LBA：`fastboot 0x0`、`bootargs 0x800`、`baseparam 0x1000`、`pq 0x3000`、
`logo 0x5000`、`kernel 0x7000`、`recoverybox32 0x11000`、`www_ecoo_top 0x31000`（十六进制扇区）。
这些是阶段 2 真正刷写 manifest 的素材，本版尚未放入 `flash.manifest`（仍零写入安全）。

**编译/校验（[观察]）**：ELF32 ARM EABI5 静态、8932 B、NEON/VFP=0、39 个 svc、soft-float；
点阵 0-9 字形模拟渲染可辨认；ramdisk 内 `sbin/recovery` == 新 flasher、内核逐字节未改；
U 盘 `recovery.img` sha256 `ad95e2c5…`、`bootcmd` 不变。

**待用户操作**：短接上电 → 屏幕会显示**一个大数字** → 报出该数字即可。最可能是
`7`（U 盘挂载失败，正好解释日志缺失）或 `8`（挂载成功、暂无 manifest）。据此决定：若 `7`
需先解决内核态 U 盘枚举；若 `8` 则下一版放 `flash.manifest` 用社区包做真正刷写。
**本版无 manifest、零 eMMC 写入，安全。**

### 10.3 数字版真机结果 = `7`（U 盘 mount 失败）+ 矛盾分析（已定案，见 §10.4）

**真机（[观察]）**：点阵数字版短接启动 → 屏幕显示 **`7`** = `udisk_mount()` 的 6 个
`(dev,fstype)` 候选 `mount()` 全部失败。数字编码按设计生效（用户能精确报告"7"）。

**用户质疑（合理）**：原厂 recovery 明明能读外部存储(U盘)上的刷机包；我们只换了用户态、
内核一模一样，为什么挂不上？

**本地查证已排除的误判（[观察]）**：
- 内核 USB host 控制器驱动齐全：kallsyms 里 `ehci`(72)/`ohci`(33)/`xhci`(173)/
  `usb_hcd`(52)/`hiusb_start_hcd_hi3798mx`/`usb_add_hcd` 全在 → **不是缺 USB 驱动**。
- `usb_stor_*`(91)、`vfat`/`vfat_fs_type`/`fat_fill_super`/`__initcall_init_vfat_fs6`(29) 全在
  且 vfat 为内建 → **不是缺 mass-storage / 缺 FAT 文件系统**。
- 原厂 `p03__init.rc`：`on init` 只 `mkdir /sdcard /system /data /cache` + 挂 tmpfs `/tmp`，
  **`on init` 根本没挂 `/usb`**；`on early-init start ueventd`；`service recovery /sbin/recovery`。

**由此定位的方向（[推断]，待反汇编定案）**：
- 原厂能读 U 盘 = **`/sbin/recovery` 进程内部用 `fs_mgr` 主动挂 `/usb`**（`p03__sbin__recovery`
  字符串含 `/usb`、`/usb/upgrade`、`/dev/block/sda`、`/dev/block/sda1`、`/etc/recovery.fstab`、
  `/proc/mounts`、`1. Apply update from external storage`、`fs_mgr: Cannot mount filesystem
  of type %s on %s`、`E:can't open the path /usb`），`recovery.fstab` 写的是
  `/dev/block/sda1 /usb auto defaults defaults`（fstype=`auto`）。
- 我们把 `/sbin/recovery` 换成 `flasher` 后，**挂载职责转移到 flasher**；而当前
  `udisk_mount()` 是"立即尝试 + 3 轮短 delay"，没有 `fs_mgr` 的 `wait_for_file` 等待。短接态
  `bootm` 交权给内核后 USB 需重新枚举、`/dev/block/sda1` 节点要等 ueventd 建 → **挂得太早 /
  节点尚未出现** 是首要嫌疑。
- 次要嫌疑：短接态 hiboot 的 `fatload usb` 用了 USB，内核起来后 host 重新枚举状态、以及
  `init.rc` 里 `android_usb` gadget(`functions adb`) 是否与 host 模式冲突，导致 sda1 根本不出现。

**后台反汇编已定案（成员，`TMP/recovery-repack/`）**：`p03__sbin__recovery`
`ensure_path_mounted`(0xae0c) 用裸 `mount()`(0x4d0e4, r7=21)；关键是
`0xae62 movs r0,#5; bl 0x54422` = **先 `sleep(5)`**，再 `wait_for_file` 用 `stat64` 轮询
节点（`0xa17c sleep(1)` × 10、`0xa180 cmp r4,#0xa`），最多等约 15s；`fstab` 的 `auto`
不传内核，依次试 `vfat→ext4→ntfs`（`msdos` 全文件 0 命中）；`flags=0xc04`
(MS_NODEV|MS_NOATIME|MS_NODIRATIME)；挂前 `mkdir(/usb,0755)`、先读 `/proc/mounts` 判已挂；
备用节点 `sda1→sda`、`mmcblk1p1→mmcblk1`，另有 `opendir("/dev/block")` 动态发现。内核
`hiusb_*` host 驱动齐全、**gadget 驱动符号 0 命中** → `init.rc` 的 `android_usb` 配置是 no-op，
不与 host 抢 PHY。[观察] 结论：**我们"立即 mount"挂得太早 + 没等待节点**，这是 `7` 的根因。

---

## 10.4 修复版：内嵌 5×7 ASCII 字模 + 对齐 fs_mgr 的挂载（本次提交）

用户两点要求：①「不要等了，多试试看」→ 把挂载策略铺开一次试够；②「有没有现成的点阵
字母 C 库，能直接打印报错消息」→ 引入字模。

**① 字模（自包含，零外部库）**：Linux 内核有 `lib/fonts/font_8x16.c` 等、嵌入式常用
`glcdfont.c`/`font5x7.h`，但本程序是 freestanding 静态 ELF（无 libc、不能链接外部库），
故把**经典 5×7 ASCII 点阵字模数据**直接内嵌进 `flasher.c` 的 `FONT[44][7]`
（`0-9 A-Z` 及 ` -.:/%!?`，等价把库的数据编译进程序）。`glyph_index()` 映射字符→字模索引。
屏幕从上版的"纯数字"升级为**大状态码数字（上）+ 英文短句（下）**：
`1 BOOT OK` / `2 MOUNT USB...` / `3 USB MOUNT OK` / `4 MANIFEST OK` / `5 FLASHING` /
`6 DONE NO REBOOT` / `7 NO USB NODE` / `8 NO MANIFEST` / `9 NO EMMC NODE` /
`70 NODE HERE MOUNT FAIL`。数字仍可精确口述，英文直接打印错误。字形模拟渲染 0-9/A-Z 全部
可辨认，布局数值模拟确认数字区(底≈559)与文字区(顶≈669)不重叠、所有短句在 1920×1080 内。

**② 挂载按 fs_mgr 重做**（`udisk_mount()`）：
- 先读 `/proc/mounts` 判 `/usb` 已挂 → 直接成功（避免 EBUSY）；`/usb/recovery.img` 可读也算已挂；
- **`nanosleep` 先睡 5s**（新增 `NR_nanosleep=162`/`NR_access=33` 与 `sleep_sec()`/`path_exists()`），
  再 12 轮 `sleep(1)` 轮询 7 个节点：`sda1/sda/mmcblk1p1/mmcblk1/sda1(dev)/sda/mnt`；
- 每个存在的节点试 8 种 fstype(`vfat/ext4/ntfs/msdos/fat/auto/exfat/fuse`) ×
  3 种 flags(`0xc04`/`0`/`0xc04|MS_RDONLY`) × 3 种 data(空/`iocharset=utf8`/`utf8,uid=0,gid=0`)；
- `g_node_seen` 记录是否曾有节点出现 → 失败细分为 `7`（无节点=USB 没枚举）与
  `70`（节点在但所有 mount 组合失败=fstype/flags 问题）。
- 刷机引擎（含 `write_sparse()` Android sparse 解码）与 best-effort 日志保持不变；
  社区包素材/LBA 见 §10.3 末尾，本版**仍未放 `flash.manifest`（零 eMMC 写入、安全）**。

**编译/校验（[观察]）**：ELF32 ARM EABI5 静态、11216 B、NEON/VFP=0、35 个 svc、soft-float；
ramdisk 内 `sbin/recovery` == 新 flasher、内核逐字节未改；U 盘 `recovery.img`
sha256 `584864ea…`、`bootcmd` 不变。

**待用户操作**：短接上电 → 屏幕显示**数字 + 英文短句**，报出即可。判定：
- `70 NODE HERE MOUNT FAIL` 或 `3/8`（挂载成功）→ 挂载已解决，下一版放 `flash.manifest` 真刷；
- `7 NO USB NODE`（节点始终没出现）→ 短接态内核 USB 未枚举，需另查（触发重新枚举 /
  用 hiboot 预加载镜像到内存等），不再是挂载参数问题。
**本版无 manifest、零 eMMC 写入，安全。**

---

## 10.5 真机 `70` → 定位到真正的根因：`NR_mount` 系统调用号写错（已修）

**真机（[观察]）**：§10.4 版短接启动 → 屏幕显示 **`70 NODE HERE MOUNT FAIL`**。
即 `g_node_seen=1`（U 盘块设备节点**确实出现了**），但所有 `mount()` 组合全失败。
→ [推断] 排除"挂太早 / USB 没枚举 / fstype/flags 不对"，问题在 `mount()` 这个系统调用**本身**。

**根因（[观察]，内核源码 + 原厂反汇编双证）**：`flasher.c` 里把 `NR_mount` 定义成了 **40**，
而 ARM EABI 的 syscall 表里 **21 才是 `mount`，40 是 `rmdir`**：
- `third_party/linux-hi3798mv100/arch/arm/tools/syscall.tbl`：
  `21 common mount sys_mount` / `40 common rmdir sys_rmdir`；
  其余号全对：`33 access` / `36 sync` / `39 mkdir` / `54 ioctl` / `118 fsync` /
  `162 nanosleep` / `192 mmap2` / `195 stat64`。
- 后台反汇编原厂 `p03__sbin__recovery` 的 `mount()` wrapper（`0x4d0e4`）实测
  `mov r7,#0x15`=**21** = mount（§10.3 已记），与此一致。

→ 之前**所有 `mount(src,"/usb",...)` 实际都调用成了 `rmdir(src)`**（r7=40），对块设备节点
执行 rmdir 必然返回失败。这**同时解释了**：
- 上一版状态码 `7`（那时还没轮询到节点就被当失败）与本版 `70`；
- 更早"彩色画面有、但 U 盘里没有 `flasher.log`"——`/usb` 从未真正挂上，日志写到了
  ramdisk 的 `/usb` 目录（断电即失），根本没落到 U 盘。

**修复（本次）**：`NR_mount 40 → 21`（`recovery-flasher/flasher.c`）。仅此一处，其余
挂载等待/多 fstype/flags/节点候选、`fb0` 点阵、刷机引擎、日志逻辑全部不动。修正后
`mount()` 会真正执行；预期这次能挂上 U 盘 → 状态码 `3/8`（挂载成功、无 manifest），
`flasher.log` 也会真正落到 U 盘。

**字号（用户要求缩到 1/4）**：加 `FONT_DIV=4`，`show_status()` 的数字 scale
`g_rows/16 → g_rows/64`、文字 scale `/4`、两者居中排布（数字在上、英文在下、留白）。
数值模拟（1920×1080）：数字 sc=16/高 112px、英文 sc 3~11、区不重叠、短句全在屏内。

**编译/校验（[观察]）**：ELF32 ARM EABI5 静态、11212 B、NEON/VFP=0、soft-float；
ramdisk 内 `sbin/recovery` == 新 flasher、内核逐字节未改。`bootcmd` 不变。
产物在 `TMP/recovery-flash-out/`（U 盘在编译/装盘时未挂载，`--install` 待 U 盘插回执行）。

**待用户操作**：U 盘插回 → `bash recovery-flasher/build.sh --install <U盘目录>` → 短接上电
→ 报数字+英文。预期 `3 USB MOUNT OK` / `8 NO MANIFEST`（挂载已通）→ 下一版放
`flash.manifest` 用社区包真刷。本版仍零 eMMC 写入。

---

## 10.6 真机 `8`（挂载成功、日志落盘）+ 更详细日志 + 首次真实刷机准备

**真机（[观察]）**：§10.5 的 `NR_mount=21` 修复版短接启动后，屏幕显示 **`8 NO MANIFEST`**，
且 U 盘根目录**真的出现了 `flasher.log`**：

```
== recovery-flasher stage1 (digits+text) ==
fb smem_len = 0x00708000
fb stride   = 0x00001400
mount /usb  = 0x00000000
node_seen   = 0x00000001
last_mnt_rc = 0xffffffff
open log    = 0x00000004
mmcblk0 node= 0x00000000
RESULT: no flash.manifest (code 8)
```

→ [推断] `mount /usb = 0`（成功）、`node_seen=1`、`open log = 4`（有效 fd，日志真落到 U 盘）、
`mmcblk0 node=0`（eMMC 块设备存在且可打开）。即：**挂载链路、HDMI 点阵显示、U 盘写日志、
eMMC 可写**这四件前置能力全部在真机上验证通过。之前缺日志确为 `NR_mount` 写错所致。

**本次改动（应"日志能写了就多记点信息"）**：在 `flasher.c` 里补齐更详细日志，全部合并进
刷机引擎这一版，不单独做"纯日志"一轮：
- 挂载诊断全局量：`g_already_mounted` / `g_seen_mask` / `g_mount_attempts` /
  `g_ok_node` / `g_ok_fst` / `g_ok_flag` / `g_ok_data` / `g_ok_pass`，`_start()` 里
  逐行写入日志（含成功时 `NODES[]`/`FSTYPES[]` 的名字）。
- sparse 解码统计 `g_sparse_chunks`/`g_sparse_raw`/`g_sparse_skip`（每次 `write_sparse()`
  入口清零，逐 chunk 累加），`do_flash()` 每个 manifest 项记录
  `idx/tokens/src/lba/bytes/kind/open src/wrote/sparse_*`。
- 修掉上次中断留下的编译错误：这三个全局量此前被 `do_flash()` 引用却未定义/未累加。

**编译/校验（[观察]）**：`build.sh` 通过；ELF32 ARM EABI5 静态、14456 B、`svc #0` 存在、
**NEON/VFP = 0**（`objdump -d` 助记符族计数 0）、soft-float。内核逐字节未改，
`ramdisk_size` 随新 flasher 更新。`bootcmd` 不变。

**首次真实刷机（[推断]+[未知] 分明，见 `recovery-flasher/flash.manifest.example`）**：
不直接写全量 OS——U 盘 `mv100/` 混入了 Debian 与社区镜像（`README.txt` 是 Debian 8 分区
说明），全量 src→LBA 对应尚未逐项核实，猜 LBA 会写坏设备。先用一条**已核实、安全、幂等**
的最小写入验证引擎：只把 `logo.img`（64KB RAW）写到 **p5 LBA 0x5000**（社区 9 分区与
Debian 8 分区下该位置都是 logo 分区，且不碰 p1/fastboot、内核、rootfs）。

权威 LBA 表来自 `scripts/make-community-flash-package.sh` 的 `flash.env`：
`p2 0x800 / p5 0x5000 / p6 0x7000 / p8 0x31000(sparse)`。

验证判据：短接上电 → 屏幕走 `1→2→3→4→5→6`，末态停在 **`6 DONE NO REBOOT`** 不重启；
`flasher.log` 里该 item 有 `wrote > 0`；断电正常开机，开机画面变为 "Debian Linux"
（证明字节写到了正确物理 LBA），且社区 Ubuntu 仍能启动（证明未破坏引导）。
全量刷机骨架在 example 里以注释给出，核实后再启用。p1 永不写，U 盘兜底始终可用。

---

## 10.7 真机首刷 `6 DONE NO REBOOT`：引擎端到端跑通；画面未变的根因是选错验证素材

**真机（[观察]）**：§10.6 版（manifest = `logo.img → p5@0x5000, 64KB, R`）短接上电：
- 屏幕显示 **`6 DONE NO REBOOT`**，走完 `1→2→3→4→5→6`，停在完成画面不自动重启 ✓
- 断电正常开机，社区 Ubuntu 正常启动 ✓（证明只写 p5 logo 未破坏引导）
- **但开机画面仍是社区版，没有出现 "Debian Linux"**（可视验证未兑现）

**U 盘 `flasher.log`（[观察]，本次首刷完整日志）**：
```
mount /usb  = 0x00000000        seen_mask=0x2, ok_node=/dev/block/sda, vfat
RESULT: manifest found, flashing
item idx    = 0x00000000
  src       = /usb/mv100/logo.img
  lba       = 0x00005000
  bytes     = 0x00010000
  kind      = RAW
  open src  = 0x00000006
  wrote     = 0x00010000        ← 真的往 eMMC 写了 64KB
flashed items = 0x00000001
```

→ [结论] **刷机引擎首次在真机上端到端验证通过**：U 盘挂载（`/dev/block/sda`, vfat,
一次命中）→ 读 manifest/镜像 → 按绝对 LBA 裸写 eMMC（`wrote=0x10000`）→ 显示状态数字
→ 停在 `6` 不重启 → 写日志到 U 盘。`NR_mount`、sparse/raw 路径、framebuffer 显示全部成立。
状态 `6` 不是"没刷"，是"刷成功且按要求不重启"。

**画面未变的根因（[观察]，非刷机失败）**：写进 p5 的 `mv100/logo.img` 哈希
`cb1a12a7…`，与 `TMP/community-restore/mv100/logo.img`（社区版 logo）**逐字节相同**
——等于把社区 logo 原样写回 p5，画面当然不变。这是 §10.6 选验证素材时的判断错误：
误把 U 盘 `mv100/` 当作 Debian 刷机包目录（其 `README.txt` 是 Debian 8 分区说明，
但 `logo.img` 实际是社区素材）。真正的 Debian 画面 `patches/kernel/boot-logo-debian.img`
哈希 `16840422…`，两者均为 `LOGO_TABLE` 容器、65536 B，可直接替换。

**修正（本版）**：把 `boot-logo-debian.img` 复制到 U 盘 `mv100/debian-logo.img`
（不覆盖社区原素材），`flash.manifest` 改指向它，仍写 p5@0x5000、64KB、R。
新 `flasher.log` 会显示 `src=/usb/mv100/debian-logo.img`。断电开机应看到
"Debian Linux" 画面 → 同时证明 p5 确实是 hiboot 开机画面来源 + 字节写到正确 LBA。
`flash.manifest.example` 已同步修正，并记下这次教训。

**安全**：仍只写 p5 的 64KB，p1/fastboot、内核、rootfs 全不碰；社区 Ubuntu 正常启动
已在上一轮验证。U 盘兜底始终可用。全量刷机映射交由后台逐项核实（不猜 LBA）。

---

## 10.8 真机修正版：Debian Linux 画面出现 + 社区 Ubuntu 网络在线，可视验证全部兑现

**真机（[观察]）**：§10.7 修正版（`flash.manifest` = `debian-logo.img → p5@0x5000, 64KB, R`）
短接上电：
- 屏幕 **`6 DONE NO REBOOT`**（走完 `1→…→6`，停在完成画面不重启）
- 断电正常开机：**看到了 "Debian Linux" 开机画面** ✓（本次可视验证兑现）
- 网络里能看到社区 Ubuntu 主机 IP、能连上去 ✓（用户确认「没毛病，主机有 IP 地址在线」）

**结论（[观察]+[推断]）**：
1. **p5 LBA 0x5000 确实是 hiboot 开机画面来源**：把内容不同的 64KB `LOGO_TABLE`
   写进去，开机画面即从社区版变为 "Debian Linux"。
2. **按绝对 LBA 裸写 eMMC 的字节落在了正确物理位置**：§10.7 的 `wrote=0x10000`
   不再只是"写了"，现在有独立可视证据证明它写对了地方。
3. 全链路坐实：U 盘挂载 → 读 manifest/镜像 → 按 LBA 裸写 → 状态数字+进度 →
   停在 `6` 不重启 → 写日志到 U 盘 → 断电后画面持久生效。
4. **重要澄清**：开机画面变成 "Debian Linux" **≠** 刷成了 Debian 系统。本次只改 p5
   的 64KB 开机图，p1/fastboot、p6 kernel、rootfs、网络配置全部未动；系统仍是
   **社区 Ubuntu**，所以网络里能看到 Ubuntu 主机 IP、能 SSH 上去是**预期结果**，
   不是异常。开机图只是 hiboot 在内核起来之前画的一张静态图，与随后启动的系统无关。

**里程碑意义**：设备从此具备"在引导/刷机阶段显示可控画面 + 按 LBA 精确改写 eMMC +
状态/进度/日志可视"的完整能力，且**不碰 p1、随时可用 U 盘兜底**。这正是本项目
前期最想要、又因无串口最难验证的能力，现已全部在真机闭环。

**下一步（[未知]，待后台核实）**：全量社区 Ubuntu 包的镜像↔LBA 权威映射由后台从
原始社区 zip 刷机脚本逐项取证（不猜 LBA），回来后产出可直接落地的全量
`flash.manifest`；在此之前 U 盘保持当前"只写 p5 logo"的安全状态。

---

## 10.9 全量刷社区 Ubuntu 的镜像↔LBA 权威映射取证 + U 盘装盘

两条独立证据链互相印证，均指向同一张表，全程只读、本地静态校验（不构建镜像）。

**证据一（[观察]，直接取证）**：社区刷机 zip (`mv100-mdmo1g-usb-flash.zip`) 顶层
`bootargs.bin`（CRC env）的 `flashpartition*` / `loadfile*` 命令，是本方案的权威 LBA 源：
```
bootcmd=run flashfastboot; run flashbootargs; run flashbase; run flashpq; \
        run flashlogo; run flashkernel; run flashrootfs; run flashbackup; reset
flashpartitionf=mmc write        0x0     0x1000000 0x0      0x0440    ; p1 fastboot
flashpartitionb=mmc write        0x0     0x1000000 0x800    0x80      ; p2 bootargs
flashpartitions=mmc write        0x0     0x1000000 0x1000   0xc       ; p3 baseparam
flashpartitionp=mmc write        0x0     0x1000000 0x3000   0x8b      ; p4 pqparam
flashpartitionl=mmc write        0x0     0x1000000 0x5000   0x120     ; p5 logo
flashpartitionk=mmc write        0x0     0x1000000 0x7000   0x7800    ; p6 kernel
flashpartitionr=mmc write.ext4sp 0x0     0x1000000 0x11000  0x20000   ; p7 recoverybox32.ext4
flashpartitiont=mmc write.ext4sp 0x0     0x1000000 0x31000  0x100000  ; p8 www_ecoo_top.ext4
```
（`mmc write` 末参是扇区数取整上界；raw 镜像应写文件真实字节数，勿照抄扇区数。）

**证据二（[观察]，后台独立复核）**：后台研究员从原版社区顶层 `bootargs.bin`
（CRC 校验通过）独立解出同一张表，并补充三条关键结论：
- `recoverybox32.ext4` = p7 OpenWrt/busybox 中继（64M, 959 chunk）；
  `www_ecoo_top.ext4` = p8 备份暂存（512M, 27 chunk，仅含 `backup-32.gz`）；
  `debian-root.ext4` 属我方 Debian 8 分区包、与社区 9 分区无关。
- [未知] **社区 Ubuntu 没有独立 p9 镜像**：docs/016 实证由 p7 `recovery.sh` 首启
  gunzip p8 `backup-32.gz` 写入 `/dev/mmcblk0p9` 再 `resize2fs`。脚本无 p9
  `mmc write`，p9 LBA `0x131000` 仅算术可推 —— **禁止写进 manifest，否则写坏设备**。
- baseparam/pq_param 脚本内有直接 `mmc write`，是必刷项（0x1000 / 0x3000）。

**三方核对（[观察]）**：
1. 8 个待刷镜像 U 盘 `mv100/` 与社区 zip 原版**逐字节 sha256 一致**
   （fastboot `3bded87f…` / bootargs `d79610fc…` / baseparam `92127cfb…` /
   pq_param `37ff404c…` / logo `cb1a12a7…` / hi_kernel `baaa86b4…` /
   recoverybox32 `273d1b5c…` / www_ecoo_top `d1ccc208…`）。
2. `hi_kernel.bin` uImage 头合法（`0x27051956`）、name=`Linux-4.4.35_ecoo_81082668`
   —— 社区内核，非 mainline，刷完能起社区系统这点已确认。
3. `mv100/bootargs.bin`（写进 p2 的社区运行时 env）与 zip 原版逐字节一致
   （`d79610fc…`）；U 盘**根** `bootargs.bin` 仍是刷机入口
   `bootcmd=fatload usb 0 0x1000000 recovery.img; bootm 0x1000000`，未被覆盖。
4. 两个 sparse 本地几何实证：recoverybox32 展开 `0x20000` 扇区(959 chunk:
   RAW+DONT_CARE)、www_ecoo_top 展开 `0x100000` 扇区(27 chunk: RAW+DONT_CARE)，
   展开区间 `0x11000..0x31000` / `0x31000..0x131000` 与脚本
   `0x11000 0x20000` / `0x31000 0x100000` 完全吻合、chunk 表完整、都在预算内。
5. 模拟 `do_flash` 解析全量 manifest：7 项 LBA/字节/格式/扇区预算全部 PASS。

**本版 U 盘 `flash.manifest`（7 项，跳过 p1，禁止 p9）**：
```
/usb/mv100/bootargs.bin       800    10000   R
/usb/mv100/baseparam.img      1000   16ac    R
/usb/mv100/pq_param.bin       3000   114e8   R
/usb/mv100/logo.img           5000   10000   R
/usb/mv100/hi_kernel.bin      7000   a5c037  R
/usb/mv100/recoverybox32.ext4 11000  0       S
/usb/mv100/www_ecoo_top.ext4  31000  0       S
```
R 字节数 = 文件真实大小；S 填 0（sparse 自描述）。p5 用社区原版 `logo.img`
（忠实复刻社区包，不再用 `debian-logo.img`）—— 刷完开机画面回到社区 logo。

**决策（[推断]，理由充分）**：
- **跳过 p1 fastboot**：p1 已是社区版 hiboot（能正常开机进社区 Ubuntu 即证）；
  短接触点兜底走 U 盘根 `fastboot.bin`，不依赖 eMMC p1。重写 p1 幂等无收益、
  却是正常开机引导链最关键一块，写坏风险不值得冒。项目红线：p1 永不写。
- **禁止 p9**：无独立镜像，写则损坏社区系统首启释放逻辑。
- **p2 同名坑**：U 盘根 `bootargs.bin`（刷机入口）≠ `mv100/bootargs.bin`
  （社区运行时 env），写进 p2 的只能是后者。

**装盘状态（[观察]）**：`recovery.img` 仍为已真机验证版（`4b688503…`，无需重编——
刷什么完全由文本 `flash.manifest` 决定，程序二进制不动）；新增盘面说明
`README-COMMUNITY-FULL-FLASH.txt`；`flash.manifest.example` 重写为全量模板。

**待用户真机验证**：短接上电 → 屏幕 `1→…→5 FLASHING`、进度 0..100（p8 294MB
sparse 展开写 512MB，会停某百分比较久，属正常）→ 停在 `6 DONE NO REBOOT` 不重启;
`flasher.log` 7 项 `wrote>0` + 两个 S 项的 sparse 统计; 断电正常开机进社区 Ubuntu、
有 IP、能 SSH = 全量刷机成功。这是**首次真机执行 sparse 写入 + 多分区 + 大镜像**,
之前只验证过单项 64KB RAW；p1 不碰、U 盘兜底始终可用，任何结果都能重刷救回。

> 注：§10.9 结尾"p8 会停某百分比较久"是[推断]，已被 §10.10 真机结果**推翻**——
> 实际刷得很快，原因见下。保留原文以示时间线，结论以 §10.10 为准。

---

## 10.10 全量刷真机结果：7 项全刷成功；"刷得快/像只刷两项"的根因

**真机（[观察]）**：§10.9 版全量 manifest（7 项）短接上电，用户反馈"很快就结束了，
好像只刷了两项"。U 盘 `flasher.log` 铁证：`flashed items = 0x00000007`，7 个 item
块齐全，逐项 `wrote` 全部等于声明字节；两个 sparse 的 `sparse_chk` 与本地几何
逐一对上。**没有漏刷，7 项全部成功**——这是首次真机执行 sparse 写入 + 多分区 +
大镜像，全部成立。

**逐项真实字节（[观察]，日志核算）**：
```
[0] bootargs.bin      RAW    LBA 0x800    wrote 0x10000  (64 KiB)
[1] baseparam.img     RAW    LBA 0x1000   wrote 0x16ac   (5804 B)
[2] pq_param.bin      RAW    LBA 0x3000   wrote 0x114e8  (70888 B)
[3] logo.img          RAW    LBA 0x5000   wrote 0x10000  (64 KiB)
[4] hi_kernel.bin     RAW    LBA 0x7000   wrote 0xa5c037 (10.4 MiB)
[5] recoverybox32.ext4 SPARSE LBA 0x11000  wrote 0x4000000 (覆盖 64 MiB)
        chunk=959(=0x3bf)  RAW落盘 0x100e000  DONT_CARE跳过 0x2ff2000
[6] www_ecoo_top.ext4  SPARSE LBA 0x31000  wrote 0x20000000 (覆盖 512 MiB)
        chunk=27(=0x1b)    RAW落盘 0x11900000 DONT_CARE跳过 0xe700000
```

**关键澄清：`wrote` 对 sparse 项是"逻辑覆盖字节"（含 DONT_CARE 空洞），不是实际
写入字节。** 恒等式成立：`wrote == sparse_raw + sparse_skip`（两个 sparse 均 OK）。
- 7 个源文件总大小 = 322566715 B = **307.6 MiB**
- 实际写进 eMMC = 322554827 B = **307.6 MiB**（前 5 项 RAW 10.6 MiB + 两个 sparse
  的 RAW 数据 297.1 MiB）
- DONT_CARE 空洞用 `lseek` 跳过、**完全不写** = 292495360 B = **278.9 MiB**
- 逻辑覆盖（含空洞）= 615050187 B = 586.6 MiB

**"为什么刷得这么快"（[观察]+[推断]）**：
1. 前 5 项 RAW 合计仅 10.6 MiB，瞬间写完。
2. 两个 sparse 虽有 16 MB / 294 MB 文件，但其中 278.9 MiB 是 DONT_CARE 空洞，
   用 lseek 跳过、零写入——sparse 格式的意义正在于此。真实落盘只有 307.6 MiB，
   eMMC 顺序写，数秒到数十秒即可完成。
3. 对比社区 hiboot 刷机（`fatload` 把整个 294 MB 读进 DDR 再 `mmc write.ext4sp`，
   且常有 2–3 分钟黑屏）：我们边读边写、跳过空洞，明显更快。

**"为什么感觉只刷了两项"（[观察]，显示层根因，非引擎问题）**：
- `do_flash()` 的进度百分比是按 **item 行数** 算的（`idx*100/total`，total=7），
  **不是按字节**；且每个 item 内部写入期间屏幕数字不刷新（`write_raw`/`write_sparse`
  一次性写完才返回，中途没有回调）。
- 于是前 5 项瞬间把数字从 0 推到 71%，一闪而过；真正耗时的只有两个 sparse 大项，
  期间数字停在 71 / 85 不动。视觉上就只剩"两下"→ 用户误以为只刷了两项。
- 这暴露进度显示的一个可改进点：按累计字节（或 sparse chunk 数）加权刷新，
  能让大镜像写入时数字持续爬升、更符合直觉。属纯显示层小改动，尚未做，
  **不影响刷机正确性**（引擎已全量验证通过）。

**断电重启观察（[进行中]，用户报告）**：拔掉 U 盘后重启"看起来挺正常，正在显示
社区版刷机包的第一张图片，等第二张"。[推断] 重刷 p7(recoverybox32 中继) +
p8(www_ecoo_top, 含 backup-32.gz) 后，社区首启恢复流程（§10.9 后台结论：p7
`recovery.sh` 把 p8 释放到 p9 再 resize2fs）被触发，这两张图正是社区包的
开始/完成进度图。**这是健康信号**：证明刷进去的社区系统被正常引导、按设计自我
恢复。预期：第二张图出现 → 进 Ubuntu → 路由器看到 IP → 能 SSH = 全量刷机闭环。
仍以真机最终状态为准，不从单张图片断言成功。

---

## 10.11 显示层改为终端式滚动日志（用户要求；刷机引擎不动）

**用户要求（[观察]）**：显示层应"左对齐、数字在每行最左边、紧跟着同行文本换行，
像普通日志一样累计换行输出，而不是每到一个新阶段就把前面阶段隐藏掉，相当于
自己做一个终端"；文字再缩小到约现在的 1/2。用户同时确认：路由器后台能看到社区
系统 IP = 全量刷机成功；刷机程序本身已足够好；下一步转向 6.x 主线内核刷机包
（上 GitHub Actions，本机不交叉编译）。并纠正方向：**main 分支本来就是给 6.x
做 CI 的，不必研究 CI 改动；真正要研究的是"启动过程怎么把画面显示出来"**。

**改动（本次，纯显示层，`recovery-flasher/flasher.c`）**：
- 删掉居中的 `render_big_number`/`render_msg`/`show_status`(清屏重画)/
  `FONT_DIV`；新增终端式：累积行表 `g_code[TERM_MAX]/g_msg[TERM_MAX]` +
  `g_nline`，`term_render()` 每次重绘**全部**历史行。
- `show_status(code,msg)` 改为"追加一行并整体重绘"：每行 `<数字> <文本>` 左对齐
  （`TERM_X0=4`），数字在行首、文本紧跟同一行、然后换行。新阶段只 append，
  **前面所有行永不被清掉**。
- 统一小字号 `TERM_SC=2`（约为原文字一半；设 1 再减半）；`TERM_MAX=64` 行、
  `TERM_STR=44` 字/行。`hold()` 保留全部日志常显、不重启。
- `state()`/`do_flash()`/`_start()` 的调用点**完全没动**，刷机引擎（mount /
  manifest 解析 / sparse / 裸写 eMMC / 日志）一行未改。

**校验（[观察]，本地轻量）**：clang 编译 ELF32 ARM 静态 15036 B、`svc #0` 在、
NEON/VFP=0、soft-float；内核逐字节未改；`build.sh --install` 装盘，U 盘
`recovery.img` 与产物哈希一致 `a5c68842…`。布局仿真：1280×720、`TERM_SC=2`
行高 16px、每屏 45 行；全流程约 21 行（5 state + 15 刷机进度 + 1 最终）全部
可见不溢出；最长行 `70 NODE HERE MOUNT FAIL` 占宽 276px < 1280px。
`build.sh` 的 U 盘 README 模板同步改为终端式说明。

**待用户真机验证**：短接上电看屏幕是不是一行行累积的 `<数字> <文本>` 日志、
前面阶段不再消失。这是纯显示改动，不影响刷机正确性（引擎已全量验证）。
真机观感（字是否够小/够清晰、行数是否够）为准，可微调 `TERM_SC`。

**方向纠偏记录**：后台只读调研（Task #29）证实 `.github/workflows/build-release.yml`
在 main 上已用 4 jobs（build-kernel ∥ build-rootfs → package → release）产出
「6.3.0-rc5 主线内核 + Debian bookworm rootfs」U 盘刷机包
`mv100-mdmo1g-debian-usb-flash-$STAMP.zip`，最新 release `build-20261108T084704Z`
已含现成产物，编译全在 CI、本机零编译。[修正，见 §10.12] 这里曾误判为"6.x
刷机包无需改 CI"——用户纠正：CI 的【刷机程序层】仍是旧的社区 hiboot
`mmc write` 脚本，必须换成验证过的 recovery-flasher 方案。内核/rootfs 编译
照旧全在 CI，本机零交叉编译。真正的技术重点是用户指出的：**主线内核启动
阶段 HDMI 显示**（mainline 缺 HiSilicon 私有显示栈 hifb/VO/VDP/HDMI TX/MMZ，
见 docs/048 与 SDK 绘图链、reserve_mem 地址推导）。

---

## 10.12 构造「recovery-flasher 刷主线 6.x」的 CI 刷机包（阶段目标）

**用户阶段目标（/goal）**：构造一个基于 6.x 主线内核、用 recovery-flasher
（原版 recovery 内核 + 自研终端式刷机程序）来刷、并**尽量让主线内核启动阶段
显示终端日志**的 U 盘刷机包。编译全部放 GitHub Actions、本机不交叉编译
（内核大、rootfs 构造耗时、依赖/网络易出问题，一次约半小时）。

**方向拆解（用户三次纠正）**：
- main 分支本就是给 6.x 做 CI 的，不用研究/重构 CI 架构；
- 但【刷机程序那一层】必须换：CI 现产出的是旧社区 hiboot `mmc write` 脚本
  （刷机阶段黑屏无进度），要换成已真机验证的 recovery-flasher；
- 研究重点应是"启动过程如何显示"，不是 CI 改动。

**关键事实（[观察]，本地核对）**：主线 8 分区
(`1M,1M,4M,4M,4M,20M,64M,-(debian)`, configs/partition-layout.env:11) 与社区
9 分区的前 8 个分区**LBA 完全相同**：p2=0x800 / p5=0x5000 / p6=0x7000 /
p8=0x31000。recovery-flasher 按绝对 LBA 裸写、与 blkdevparts 无关，故被刷
内容从"社区 4.4 内核 + 社区 rootfs"换成"主线 6.x uImage(hi_kernel.bin) +
Debian rootfs(sparse)"后，LBA 与 flash.manifest 格式照用即可。

**实施（本次）**：
1. 新增 `scripts/make-recovery-flash-package.sh`：复用
   `make-community-flash-package.sh` 产出的 `build/community-package/pkg/mv100/`
   主线镜像（p2 runtime env / p5 logo / p6 主线 uImage / p8 Debian rootfs
   sparse），只替换【刷机程序层】——U 盘根 `bootargs.bin` 从 hiboot mmc-write
   脚本改为 recovery 入口（`fatload recovery.img; bootm`，由
   `recovery-flasher/build.sh` 生成），并加入 `recovery.img`（原版 recovery
   3.10 内核 + 终端式 flasher）与 `flash.manifest`（4 项，LBA 同上，R 字节数
   取文件真实大小、S 填 0）。p1 fastboot 永不写。产物
   `mv100-mdmo1g-mainline-recovery-flash-$STAMP.zip`。
2. 改 `.github/workflows/build-release.yml` 的 `package` job：
   - 依赖加 `clang lld`（仅编译 15KB ARM flasher ELF，非内核交叉编译）；
   - 原 community 包降级为 "(legacy fallback)"，其后新增一步构建
     "(recommended)" recovery-flasher 主线包；
   - 固定 STAMP 同时显式传给两个脚本（消除 GITHUB_ENV 跨步导致的时间戳
     错位）；release notes 增加 recommended 包、刷机流程、显示判据，标题更新。
   - build-kernel / build-rootfs / qemu-boot-test 三个 job 完全不动。

**"启动显示"如实标注（[观察]+[推断]，不猜显存地址）**：刷机阶段的终端日志
由 recovery-flasher 提供（真机已验证）；主线内核启动阶段的显示是 best-effort、
未经真机验证。内核已带 `console=tty0 fbcon=map:0 clk_ignore_unused`
(partition-layout.env:35)、`CONFIG_FB/FB_SIMPLE/FRAMEBUFFER_CONSOLE/VT`
(ec6108v9c.config:31-38)、simplefb/hdmi-console 交接驱动 + pstore/ramoops。
后台调研 (Task #30) 证实卡点：静态 simplefb 节点因 `fb_base` 默认空而未生成、
显存基址跨次不稳定（未知），故本包**不猜地址、不强行填 FB_BASE**，判据三件套
（logo / 绿带 / IP）见 README 与 release notes；HDMI+SSH 全黑时靠 pstore 兜底。

**校验（[观察]，本机轻量，未编译内核/rootfs/未碰 U 盘/eMMC）**：
`bash -n`、YAML 解析（4 jobs / package 10 steps 正确）、脚本用假镜像与真实
主线镜像各跑一遍均 6 步通过；静态校验 recovery 入口 CRC / ANDROID! 头 /
4 项 LBA / p1 不写；模拟 `do_flash` 解析确认声明 bytes 与文件真实大小一致。
**待 CI 真机验证**：release 产出 zip 后短接上电 → 终端式 "6 DONE NO REBOOT"
→ 断电开机看 logo/绿带/IP。CI 全量构建留 GitHub Actions，本机不等待、不取消。
