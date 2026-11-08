# 049 — 触点引导「纯显示探针」程序（刷机阶段可见性的第一阶段产物）

> 2026-11-08。用户新目标把工作收敛为：**写一个能通过触点（USB_BOOT 短接）引导的刷机程序，
> 放 U 盘、快速迭代；第一阶段只解决「刷机/引导阶段能显示颜色或进度条」，实际刷机动作先不做。**
> 本文记录据此落地的**可运行产物**的设计、证据、判定表与迭代方法。
>
> 相关文档：`docs/035`（recovery 内核 MMIO 序列）、`docs/036`（刷机执行者 = p1/U 盘根 hiboot）、
> `docs/038`（BootROM USB_BOOT 从 U 盘根加载 `fastboot.bin`）、`docs/040`（在线写 fb0 实证）、
> `docs/045`（这份 p1 里显示实现是 dead 符号池）、`docs/048`（SDK 源码级绘制链路 + 显存地址推导）。
> 方法：`docs/033 §2` REA 三分法 `[观察]/[推断]/[未知]`；不编造地址；不改 p1、不刷分区。

---

## 0. 结论先行

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| 1 | **产物是什么**？ | 一个 U 盘根三件套：`fastboot.bin`（社区已验证载体，BootROM 短接加载）+ `bootargs.bin`（bootcmd 仅 `fatload+go`）+ `display.bin`（本机编译的 armv7 裸机程序）。**不含刷机包**：无 kernel、无 rootfs、无分区镜像、无 `mmc write`、无 `reset`。 | [观察] |
| 2 | **display.bin 做什么**？ | 持续往 4 个已定案的候选显存物理地址填「绿色进度条 + 深蓝背景」，进度循环增长（可见动画）。**纯 DDR 写，不写任何 MMIO 寄存器**（不碰 VO/HDMI/CRG/PHY），绝不把盒子搞到无法重刷。 | [观察] |
| 3 | **它验证什么**？ | 唯一决定性未知：**触点短接的刷机/引导阶段，VO/HDMI 是否已在扫描 DDR 顶端的显存**。若出现绿色进度条 → 实时进度显示只需写像素，无需改 p1、无需图片资源、无需 HDMI 初始化；若全黑 → 该阶段根本无 HDMI 输出，下一版按 `docs/035` + SDK 加 VO/HDMI/PHY 初始化序列再填色。 | [推断] |
| 4 | **为何可快速迭代**？ | `bootcmd` 永远指向 `display.bin`；首次安装后，改 `display-probe/probe.S` → 跑 `build.sh` → 只把新的 `display.bin` 拷回 U 盘即可，其余两文件不动。本机 `clang + ld.lld` 全量重建 < 1 s，无需 CI、无需 rootfs 构建。 | [观察] |

---

## 1. 为什么是这个形态（链路与证据）

### 1.1 引导链（[观察]+[推断]）
短接 USB_BOOT 上电 → BootROM 从 U 盘 FAT32 根加载 `fastboot.bin` 到 RAM 执行（`docs/038`，
histb 文档级证据）→ `fastboot.bin` 是链接在 `0x00C00000` 的裸 ARM hiboot（首字 `0xEA000819`
复位向量 + 异常向量表，4 份构建一致）→ 它读 U 盘根 `bootargs.bin`（CRC32 env），执行 `bootcmd`
（`docs/036`）。社区刷机链 `bootcmd` 第一步就是 `fatload usb 0 0x1000000 mv100/...`，证明**这一阶段
USB + fatload + 内存写可用**。

我们把 `bootcmd` 改为：
```
fatload usb 0 0x01000000 display.bin; go 0x01000000
```
`go` 命令存在（fastboot 内 `start application at address 'addr'` help 串实证），偶地址按 ARM 态跳转。
`display.bin` 链接/加载地址均为 `0x01000000`（16 MiB），远离 `fastboot.bin`（0x00C00000）与其栈。

**env 不精简**：`bootargs.bin` 以社区原版 U 盘根 env 为模板，保留全部非隐私 key
（尤其 `bootargs_1G=mem=1G mmz=...`、`filename=fastboot.bin`、`partition*`、`bootdelay`），
**只替换 `bootcmd` 一行**。原因：显存地址 `0x3FBFD000…` 正是按 `mem=1G` 推导的，`docs/048 §2`
的 `Reserve Memory` 表也对应 `mem=1G`；若 env 里缺 `bootargs_1G` 导致 hiboot 换了 DDR 布局，
地址就会偏，造成假阴性。刷机专用的 `loadfile*`/`flash*` 变量与网络占位 IP/MAC 一律去掉
（不被 `run`、且避免隐私），使这份 env 明确「不是刷机包」。

### 1.2 显存地址为何固定（[观察]+[推断]，推翻此前「地址不可知」）
多份独立 `mem=1G` 启动日志的 `Reserve Memory` 表完全一致：`Start 0x3FFFE000` /
`Alloc 0x3FBFD000 0x400000`(4 MiB) / `0x3F8FC000 0x300000`(3 MiB) / `Free 0x3F8FC000`；
`docs/048 §2` 用 SDK `reserve_mem.c` 源码算法逐行复现吻合（`reserve_mem_free -= size+0x1000`，
从 DDR 顶端向下）。`docs/040` 在线实测 `fb0 smem_start=0x3C55C000`、`docs/041` VO layer0
`0x3F6CE000`。程序把这 4 个候选**全部**填色，最大化命中「此刻 VO 在扫哪块」的概率；
每块只写 1 MiB，全部落在 `mem=1G` 的 DDR 内、远离顶端边界，不越界。

**[未知]**：这几块里哪一块是当前扫描缓冲、短接刷机态 VO 是否已初始化、跨次上电是否恒定。
本探针正是用真机给这三个未知定案。

### 1.3 为何第一版不碰 MMIO（[推断]）
`docs/045` 证明我们备份的这份 p1 里显示实现是 dead 符号池、刷机分支不做显示初始化；
用户实测社区刷机「最初两三分钟也全黑、不显示进度」。因此「刷机态 VO 是否在扫描显存」
是纯未知，两种可能：① 已在扫描黑帧（那填色即可亮）→ 本版直接成功；② 无 HDMI 信号
（怎么填都不亮）→ 需要 `docs/035` 的 PHY/CRG/VO 初始化序列。第一版选**最小、零风险**路径：
只做 ① 的验证，绝不引入写坏时钟/PHY 的风险。按结果决定第二版。

---

## 2. 产物与文件

| 文件（仓库内相对路径） | 作用 |
|---|---|
| `display-probe/probe.S` | armv7 裸机汇编：关中断 → 循环给 4 块显存填进度条 → 忙等 → 重复 |
| `display-probe/build.sh` | 编译 + 生成 `bootargs.bin` + 组装 U 盘三件套 + 可选 `--install`（带备份） |
| `TMP/display-probe-out/` | 构建产物（gitignored）：`display.bin`/`bootargs.bin`/`fastboot.bin`/`README.txt` |

`bootargs.bin` 用仓库内 `scripts/mkbootargs.py` 生成，格式 `[4B LE CRC32][NUL 分隔 key=value][补零到 64KiB]`；
生成后 CRC 头与重算值一致、反汇编 literal pool 自洽、bash `-n` 通过——均为提交前校验项。

**隐私/合规**：源码、脚本、文档、commit message 无本机绝对路径 / 用户名 / IP / 凭据；
产物只放项目内 `TMP/`；不删任何文件、不用 `git clean`/`rm`；`--install` 先把 U 盘原 `bootargs.bin`
备份到 `TMP/display-probe-out/backup-bootargs.bin`（可随时拷回恢复社区刷机包）。

---

## 3. 判定表（真机现象 → 结论 → 下一步）

| 现象 | 结论 | 下一步 |
|---|---|---|
| 屏幕出现**增长的绿色进度条/彩条** | 刷机引导阶段 VO 正在扫描这些 DDR 区 → 实时进度显示成立 | 把 `probe.S` 的填色换成真实刷机步骤进度映射；或移植到刷机链 bootcmd 的 `mw.l` 换色，零图片资源 |
| **花屏 / 局部色块 / 错行** | 地址对了，stride/分辨率/像素格式不对 | 读 VO `G0_STRIDE/G0_IRESO` 或按 `docs/040` 的 1920×1080 ARGB8888 stride 7680 调几何 |
| 盒子**无法再进社区系统** | 不应发生（本程序不写 eMMC/p1） | 用同一短接流程重刷社区包；检查是否误用了非本目录的 bootargs.bin |

**「全黑」不是单一结论**（REA：别把「没显示」直接归因于「VO 未初始化」）。全黑至少四种可能，需逐项排除：

| 可能 | 判据 / 下一步 |
|---|---|
| ① 该阶段 HDMI/VO 根本未初始化（无信号，非扫描黑帧） | 最可能（`docs/036 §4.2` + 刷机分支 boot log 无 GFX 行）。第二版在 `display.bin` 开头加入 `docs/035` 表 A 的 HDMI PHY 7 次静态写 + CRG 复位/时钟 + VO G0 层配置（`docs/048 §1`），再填色 |
| ② `fatload`/`go` 根本没执行到（env 或 CRC、文件名、加载地址问题） | U 盘根 `bootargs.bin` CRC、`display.bin` 文件名/位置、`go` 是否加载成功均无串口可看；可先用一个**必定可见的极简变体**（如 `probe.S` 改为纯写 `0x1000000` 再另法验证），或改 `bootcmd` 加一条能改变可观察 LED 状态的命令 |
| ③ 写入落在 write-back DCache 未回写（VO 扫 DDR 看不到） | 程序已加 `dsb sy`；若仍疑似，下一版在开头关 DCache/MMU 或用 `mw.l`（经 hiboot，cache 策略已知）复现 |
| ④ 4 个候选地址都没命中当前扫描缓冲 | 用真机在线态读 `G0_ADDR`（`docs/040` 方法）标定真实地址后写死；或扩大候选到 `reserve_mem` 全表 |

**关键**：无论哪种，第一版都**不写任何 MMIO、不刷分区、不 reset**，因此盒子永远可重刷、绝不砖。这正是先做「零风险定案」而非一上来就堆完整 HDMI 初始化的原因。

---

## 4. 迭代方法（用户操作）

1. 首次：`bash display-probe/build.sh --install <U盘挂载目录>`，把三件套放到 U 盘根。
2. 短接 USB_BOOT 触点，上电，看 HDMI 现象，对照 §3 判定表。
3. 迭代：改 `display-probe/probe.S`（颜色、显存地址、加 MMIO 初始化等）→ `bash display-probe/build.sh`
   → 只把 `TMP/display-probe-out/display.bin` 拷回 U 盘根覆盖 → 再次短接上电。
4. 恢复社区刷机包：把 `TMP/display-probe-out/backup-bootargs.bin` 拷回 U 盘根覆盖 `bootargs.bin`。

---

## 5. 与总目标的关系

本产物只完成「启动/引导/刷机阶段显示可见性」的**第一阶段：显示 proof**，
不含刷机动作（用户明确「实际刷机动作暂时可以先不做」）。待 §3 定案「刷机态能否点亮像素」后，
再决定是否：(a) 直接写显存做实时进度；(b) 重写自定义引导/刷机程序携带完整显示栈；
(c) 分阶段 U 盘包 + 阶段色块（`docs/046`）。所有后续方案都不改 p1、不依赖 pstore。
