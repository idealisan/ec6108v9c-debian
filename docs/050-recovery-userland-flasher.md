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

## 0. 结论先行

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| 1 | **改造原厂 recovery 可行吗？** | **可行，且原料/工具链本机齐备**。保留原厂 3.10 内核（自带 hifb/VO/HDMI 驱动，负责点亮 HDMI + 注册 `/dev/graphics/fb0`），只替换 ramdisk 里 `sbin/recovery` 一个用户态文件。 | [观察] |
| 2 | **为何比"裸机从零点亮 HDMI"靠谱？** | 裸机 `go` 后无内核/时钟框架；成员查实 CRG/PLL/`G0_ADDR` 多为运行时 RMW/动态地址（`docs/035`），静态直写几乎不可能一次成。复用内核则显示栈现成，用户态只需 `open(fb0)`+写像素（`docs/040` 实证）。 | [观察]+[推断] |
| 3 | **短接态怎么加载？** | 社区 `fastboot.bin` 的 `bootm` **直接 boot Android boot.img**：`check_header` 仅 memcmp 8 字节 `ANDROID!`，`get_ramdisk` 反汇编实证把 ramdisk `memcpy` 到 `0x04e00000` 并作 initrd。故 `bootcmd=fatload usb 0 0x1000000 recovery.img; bootm 0x1000000`。无需转 uImage/DTB/单独 ramdisk。 | [观察]（成员反汇编） |
| 4 | **零交互自动执行？** | `init.rc` 已有 `service recovery /sbin/recovery` + `on early-init start ueventd` + `on boot class_start default`，上电自动拉起；替换后的程序无菜单、无按键依赖。 | [观察] |
| 5 | **刷机动作？** | 程序挂载 U 盘到 `/usb`（`recovery.fstab` 有 `/dev/block/sda1 → /usb`），若存在 `/usb/flash.manifest` 则按行 `<src> <LBA-hex> <bytes-hex>` 把镜像按**绝对 LBA 裸写** `/dev/block/mmcblk0`，逐项推进进度条；无 manifest 则纯显示、**零 eMMC 写入**。 | [观察]+[推断] |
| 6 | **真机显示已证实？** | **否**。产物已编译、重打包、逐字节校验通过，但短接态内核能否点亮 HDMI 仍是决定性未知。必须先做 §5 两段式 go/no-go 的第 1 步（boot 未改镜像看原厂 UI）。 | [未知] |

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
| `recovery-flasher/flasher.c` | freestanding ARM Linux 静态程序：自动拉起、`fb0` 进度条、manifest 自动刷机、常驻不退出 |
| `recovery-flasher/repack.py` | 从 `p03_recovery.img` 切 boot.img、cpio newc 手术替换 `sbin/recovery`、重打包、产出验证/改造两镜像 |
| `recovery-flasher/build.sh` | 一键：编译 flasher → repack → 生成 `bootargs.bin` → 组装 U 盘三件套（可 `--verify` / `--install`） |
| `TMP/recovery-flash-out/` | 构建产物（gitignored）：`flasher`/`recovery.img`/`recovery-verify.img`/`recovery-flash-boot.img`/`bootargs.bin`/`README.txt` |

**工具链**：本机 `clang --target=armv7-unknown-linux-gnueabihf -fuse-ld=lld -static -nostdlib`
即可产出 ELF32 ARM EABI5 静态 EXEC（freestanding syscall 直发 `svc #0`，自制 `__aeabi_uidiv`），
无需交叉 gcc / libc / sysroot / CI，全量重建 < 1 s。

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

**隐私/合规**：源码/脚本/文档/commit 无本机绝对路径/IP/用户名/凭据；产物在 `TMP/`（gitignored）；
不删文件、不用 `rm`/`git clean`；显式 `git add <具体路径>`；`--install` 先备份 U 盘原 `bootargs.bin`。
内核 blob 未进入 git（只在 `TMP/`）。

## 5. 两段式 go/no-go（用户操作，决定性）

短接态内核是否"从零"点亮 HDMI 仍未定案（社区 4.4 似只继承 hiboot 的 VO 状态，而刷机分支
hiboot 不初始化显示）。**先分离这个变量，别一上来就刷改造版**：

1. **第 1 步（验证内核）**：`bash recovery-flasher/build.sh --verify --install <U盘目录>`
   → 把**未改的** `recovery-verify.img` 作为 `recovery.img`。短接 USB_BOOT 上电。
   - 出现**原厂 recovery 界面/文字** → 内核在刷机态点亮 HDMI、fb0 可用 → 本路线成立，进第 2 步。
   - 仍**全黑** → 内核也不从零初始化 HDMI → 本路线与裸机路线皆败，需回到 `docs/023 §5.2 第二阶段`
     或引入 hiboot 正常开机画 logo 后再进 recovery（多一次 reset）。**停止，勿继续堆改造。**
2. **第 2 步（改造版）**：`bash recovery-flasher/build.sh --install <U盘目录>`（默认，替换 `sbin/recovery`）
   → 短接上电，应看到进度条；放 `/usb/flash.manifest` 则自动刷机。

## 6. 仍未定案（[未知]，真机才能定）

1. **决定性**：短接态 3.10 内核是否独立初始化 HDMI/VO（§5 第 1 步）。
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
