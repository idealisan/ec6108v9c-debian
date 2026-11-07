# 025 — 主线显示驱动移植调研（pmOS 方法论 + histb-mainline 现成成果）

> 2026-11-07 调研。目的：确定「刷机后黑屏/无 IP」之后的**主线移植**路线，
> 并把搜到的外部资料固定下来，避免遗忘。
>
> **用户拍板**：一定走主线移植这条路（不是 downstream/vendor kernel 打包）。
> 另一个项目 `smartisan-odin-debian` 已成功实践过该方法，本仓库仅作**方法/策略参考**。

---

## 0. 一句话结论

**Hi3798MV100 的 HDMI/显示驱动已经有人移植到主线内核（Linux 7.3/7.4）并成功点亮了，
而且补丁集、板级 DTS（就是我们这块 EC6108V9C）、DRM 驱动全部开源可拿。**
我们不必从零写驱动，正确做法是复用/移植 `histb-mainline` 的补丁系列。
`console=tty0` 是必需条件 —— 这一项我们早就有了。

---

## 1. postmarketOS 的方法论（搜到的）

### 1.1 两条路线，别混淆

| | downstream (vendor) kernel | mainline / close-to-mainline |
|---|---|---|
| 做法 | 用厂商提供的内核源码（通常 Android fork），补配置，跑标准 Linux 用户空间 | 用 kernel.org 上游内核 + 设备补丁（DT、驱动） |
| 前提 | 厂商开源内核 | 上游必须有该 SoC/外设驱动 |
| 工作量 | 相对简单，新 port 的常见起点 | 几小时（只写 DTS）到几个月（驱动全从零写） |
| 代价 | 老内核、无安全更新、代码质量差、常依赖 Android HAL/blob | 需要把 device-specific code **port 并 clean up** |

来源：wiki.postmarketos.org「Mainlining」「Porting to a new device/Kernel package」。

### 1.2 「移植安卓驱动」的真相（重要，纠正直觉）

pmOS wiki 原文要点：
- Mainlining = **porting (and most importantly: cleaning up) device-specific code
  from the downstream kernel to the mainline kernel**，不是把 vendor 驱动原样搬过去。
- "Often large parts of the drivers are moved into proprietary parts in Android
  userspace — generally impossible to use without emulating the expected Android
  environment. ... the effort to make such drivers work properly on long term is
  often as much as **rewriting them properly for mainline**."
- Ubuntu Touch Q&A 更直接："Could vendor kernels be patched to Mainline standard?
  ... an immense task ... create new compatibility layers ... **In practical terms,
  that is an impossible task.**"（指把整个 vendor kernel 抬到主线标准）

→ 所以「最差情况就是像 pmOS 一样移植安卓驱动」这个说法要修正：
**pmOS 的主流做法是先把整个 downstream kernel 跑起来**，而把单个显示驱动
backport 到跨大版本的新内核，社区普遍认为接近重写。
好在我们有全栈 SDK 源码（`source/msp/drv/...`、`hi_reg_vdp.h` 10700 行），
比 pmOS 常见的「无源码 vendor blob」处境好得多。

### 1.3 显示相关的具体套路（Qualcomm mainline porting wiki）

1. **先建立反馈通道**（调试生命线），按优先级：
   - UART 串口（最有用）
   - **Simple Framebuffer**："easiest method ... provided you have a video-mode
     panel and your bootloader leaves a framebuffer configured for continuous
     splash" —— 内核把日志打到屏幕，在写 panel 驱动之前就能用
   - RAM console / ramoops（last resort）
   → **我们做的 simplefb + pstore 正是这一套**。
2. **面板/显示初始化序列从下游来**：
   "A display driver can be generated from the downstream devicetree using
   linux mdss dsi panel driver generator ... Often times the generated display
   driver works without changes."
3. **面板驱动生成的 DSI 命令可与 Android 实测对比**：给 vendor kernel 打 printk，
   把 `dsi_panel_tx_cmd_set` 的命令 dump 出来对照。
4. **"Trojan Horse" 面板法**（Xperia 5 II 实战，GitHub pdx206-mainline）：
   bootloader 已经初始化好面板，内核**不需要重新初始化**；只需在 DTB 里塞一个
   能让 DRM 驱动 chain 完整的 panel 节点（compatible 用最接近的上游驱动），
   init 序列重复也无害。→ 与「cont-splash 接管」同思路。
5. **simplefb 的坑**（mainlining.dev / gist）：
   - `reserved-memory` 的 cont-splash 节点必须加 **`no-map`**，否则 ioremap 会
     non-fatal kernel panic
   - `status = "okay"`、`format = "a8r8g8b8"`、`stride = width*4`
   - SDM845 wiki：**必须 `&dispcc { status="disabled"; }` / `&gpu { status="disabled"; }`**，
     否则显示时钟初始化会重置 bootloader 设好的状态导致黑屏
   → 对应我们的 `clk_ignore_unused`；但主线正解是**主动 enable 需要的时钟**，
     不是全量忽略。
6. **prebuilt kernel 不可行**：从设备直接抠出的预编译内核 "will not work"，
   缺 pmOS 需要的 config 选项。→ 我们从源码编译是对的。

### 1.4 调试优先级（wiki 反复强调）

先想办法拿到内核输出（UART > simplefb > ramoops），
再谈驱动。我们目前正是卡在"没有任何输出"，
所以 pstore/ramoops（已加）+ 换 logo 标记（已加）是正确方向。

---

## 2. 策略参考仓库：`smartisan-odin-debian`（用户之前成功的项目）

该参考工程为本地私有仓库，不在本仓库内，文档也不记录其本地路径；这里只借鉴它的工作准则与主线化策略。

**形态**：Smartisan ODIN（msm8953/SDM450）主线 Linux 6.19 + Debian 12 移植，
真机已点亮屏幕、SSH/WiFi 打通。pmOS 风格工程。

### 2.1 它的工作准则（AGENTS.md「铁律」）——与我们高度一致

1. 每个命令前 `date` 打时间戳
2. 完成一点就立即 commit + push
3. **只增不删**：禁 `rm` / `git clean` / `git gc --prune`；清理留到最后经用户确认
4. **制品一律以 CI 构建为准**；本地/直接改真机只是探路，不能据此确认修好
5. 项目自包含，默认路径不指向仓库外
6. 临时文件放本文件夹 `tmp/`，不用 `/tmp`
7. 联网 IO 走后台任务，短轮询
8. 不自己写 shell 轮询（macOS 无 GNU `timeout`）
9. **外部仓库走子模块，分两组**：构建必需（内核、lk2nd）与
   **仅参考（官方安卓内核源码，`ext/smartisan-kernel`，刻意不在构建中拉取）**
10. 别把 workaround 当需求（先问它解决什么，有没有更直接的修法）

→ 第 9 条正是用户「备份只作策略参考」的对应实践。

### 2.2 显示驱动怎么变成主线补丁（README §一）

补丁清单里的显示部分：
- `0004/0005/0006` `drm/panel`：R69006 / FT8716 / NT36672 三种面板驱动
- `0007` 板级 DTS
- `0008` **修黑屏**：把面板初始化序列从 `.prepare` 挪到 `.enable`
  —— DSI 主机未上电时 `dsi_host_transfer()` 静默返回 `-EINVAL`，
  prepare 阶段发的命令一条都不生效。**这是「能编译但黑屏」的经典坑，
  和我们的症状同类。**
- **「所有初始化序列逐字节取自原厂 DTB」**：用
  `linux-mdss-dsi-panel-driver-generator` 从 boot.img 的 DTB 自动生成后合并。
- 多面板自动选择靠 bootloader（aboot）GPIO strap 检测 + cmdline 名字透传 +
  DT compatible 替换；lk2nd 的 `cont-splash` 形态**从不初始化面板**，
  只复用上一棒画好的帧缓冲。

→ 可迁移的经验：**初始化序列要从原厂资产自动生成/逐字节核对，不要手写猜；
驱动 probe 时机（prepare vs enable / initcall 顺序）会决定黑屏与否。**

### 2.3 目录形态

`patches/`（0001-0010 补丁集）、`dts/`、`ext/`（子模块）、
`dist/`（刷机包与用户态源码）、`reports/`（专题报告 001-021）、
`WORKLOG.md`（追加式流水账）、`docs/`、`tmp/`。
二进制产物（镜像/DTB/.ko）**不入库**，统一 GitHub Release 资产。

---

## 3. 决定性发现：`histb-mainline` 已经把 mv100 显示移植好了

### 3.1 论坛实锤

`https://bbs.histb.com/d/4770/6`「**Linux 7.3 mv100 HDMI 成功点亮**」
- 作者 Ggthifb，2026-10-05 发布，"经过一周奋战…成功在主线上驱动 mv100 HDMI 输出"
- **"需要在 cmdline 添加 console=tty0 才能在屏幕上看到 dmesg"**
- "HDMI 完成，现在开始攻硬解驱动"；跟帖 "is work!"（有 HDMI 输出截图）
- "我已经完成了 **mv100 所有驱动**"（gthifb 2026-10-24）
- 提到组织 `https://github.com/histb-mainline`（开 3 年）
  → 我们有 `console=tty0`，条件已满足。

### 3.2 组织与仓库

`https://github.com/histb-mainline`
> Open-source software/firmware for HiSilicon Hi3716 / Hi3796 / Hi3798 devices
> **Currently tested: Hi3716cv200, Hi3798mv100, Hi3798mv200h.**

| 仓库 | 说明 |
|---|---|
| `linux` | 主线内核 fork（forked from torvalds/linux），**Hi3798MV100 支持**，Updated 2026-11-05 |
| `patches` | **Out-of-tree Linux patches（quilt）**，Updated 2026-11-05 ← 最有用 |
| `histb-stage1` | 从 HiSTB fastboot 到 TF-A |
| `hiloot` | HiTool 开源替代（串口 bootstrapper） |
| `tracker` / `snippets` / `l-loader` | 辅助 |

### 3.3 `patches` 仓库结构（OpenWrt 风格）

```
baseline          内核版本 + 每个补丁适用的 BASE_SHA
series            补丁应用顺序（source of truth，git 分支不算）
quilt.conf        --fuzz=0
backport-7.4/     从其它内核版本取的补丁（暂无）
pending-7.4/      可提交（submittable）补丁  ← 154 个文件
hack-7.4/         本地 only（bring-up 调试工具，990-SS，不提交）
```
- 基线内核 **7.4**（`KERNEL_VERSION` in `baseline`）
- 命名 `NNN[-SS]-<chip>-<shortname>.patch`，chip ∈ {mv100, cv200, mv200, mv200h, all}
- 百位 = submission class（依赖顺序）：0xx 共享 ABI（dt-bindings/vendor prefix）、
  1xx 修复、2xx-8xx 新驱动（百位即规模档）、9xx 板级集成、990 hack
- 规模：`drivers/gpu/drm/histb/` = **7,690 行**（6xx 档）、`drm/bridge/` = 2,430 行（5xx）

### 3.4 与我们直接相关的补丁（已下载到 `TMP/histb-ref/`）

**显示/DRM 驱动（600-\* 系列，22 个）：**
| 补丁 | 内容 | 大小 |
|---|---|---|
| `600-01` | `drm/histb: add vdp v2 display engine driver` | 66 KB |
| `600-12` | `drm/histb: add the shared vdp display core` | 17 KB |
| `600-14` | `drm/histb: add the vdp v4 display engine` | 66 KB |
| **`600-17`** | **`drm/histb: add the on-chip HDMI transmitter driver`**（新建 `drivers/gpu/drm/histb/histb-hdmi.c`，1392 行） | 46 KB |
| **`600-18`** | **`drm/histb: hdmi: bring the video path up on the transmitter`**（223 行改动） | 15 KB |
| `600-19/20/21` | Kbuild / 配置合并 | 小 |
| `600-22` | cv200 VDP dt-bindings schema | 6.6 KB |

**HDMI bridge / bindings：**
- `500-01` `dt-bindings: display: add the histb hdmi schema`
- `500-02` `drm/bridge: add the sii9134 hdmi transmitter`（82 KB）

**mv100 时钟（替换 clk_ignore_unused 的正解）：**
- `400-01` `dt-bindings: clock: add the hi3798mv100 crg ids`
- `400-02` `clk: hisilicon: add crg driver for hi3798mv100`（36 KB）

**板级 DTS —— 就是我们这块板（910-\* 系列）：**
| 补丁 | 内容 |
|---|---|
| `910-01` | `ARM: dts: hisilicon: add the hi3798mv100 soc include` |
| **`910-02`** | **`ARM: dts: hisilicon: add the Huawei EC6108V9C board`**（374 行，2026-10-10） |
| `910-03` | `ARM: dts: hisilicon: describe the hi3798mv100 VPSS block`（2026-11-03） |
| `910-04` | mv100 thermal |
| `910-06` | `ARM: dts: hisilicon: build the ec6108v9c board` |
| `910-08` | hi3798 CPU 描述 |

**`910-02` 板级 DTS 的关键内容（已读原文）：**
- `model = "Huawei EC6108V9C"`，`compatible = "hisilicon,hi3798mv100-ec6108v9c", "hisilicon,hi3798mv100"`
- 描述 eMMC pinconf/reset GPIO、IR、三颗状态 LED、AIAO 声卡
- **`reserved-memory` 里 `media_cma: media-cma`**：显示控制器与解码器共享的
  媒体池，注释明确写：
  > "A frame buffer has to be physically contiguous, because the channel takes
  > one base address (**VO_G0_ADDR**) and **this chip has no MMU on the
  > display side**"
  → **与我们驱动里的 `VO_G0_ADDR` 同名、同一寄存器概念**，交叉印证了
  `docs/023` 里从 SDK 推出的 G0_ADDR。
- `&hdmi { status = "okay"; }` 等显示/音频/图形节点全部 switch on
- 显示侧预算：fbdev console + 双缓冲 UI = 3×O

**`hack-7.4/` 调试工具（990-\*，跟我们 /dev/mem 探测同思路）：**
- `990-11` `drm/vdp4 bring-up instruments`（29 KB）
- `990-12` `drm/hdmi bring-up instruments`（12 KB）
- `990-13` `drm/histb read-only register snapshot`
- `990-10` `drm/vdp2 bring-up bench content`
- `990-23` bench harness（443 KB）

---

## 4. 对我们现状的诊断（为什么之前黑屏）

对照第 1、3 节，我们之前那条路线的问题：

1. **simplefb「接管 hiboot 显存」的前提不成立/不稳**。pmOS 的 simplefb 要求
   "bootloader leaves a framebuffer configured for **continuous splash**"，
   而这块板 hiboot 画 logo 用的是私有 VO 层，社区系统本身也没接 fbcon。
   我们读 `VO_G0_ADDR`(0xf8cc0000+0x494) 拿到的地址、以及该地址是否
   仍被持续扫描、是否落在内核已分配的 RAM 里，全都是**未验证假设**
   （`docs/024` §3.3/§3.6 已列）。
2. **显存与内核内存冲突**：主线正解是 `reserved-memory` + `no-map` 自己
   分配（histb `media_cma`），而不是事后从寄存器里捞一块被内核当普通 RAM
   的地址来 `request_mem_region`。
3. **时钟**：主线正解是主动 `clk_get/enable`（`400-02` CRG 驱动），
   `clk_ignore_unused` 只是权宜；SDM845 wiki 明确说显示时钟被重新初始化
   会重置 bootloader 状态导致黑屏。
4. **probe/初始化时机**：odin 项目 `0008` 的黑屏修复说明，
   初始化序列发得太早（主机未上电）会静默失效。

→ 结论：**与其继续调 simplefb 交接，不如直接上 `histb-mainline` 的
完整 DRM 显示驱动**。它自己分配显存、自己初始化 VO/HDMI/时钟，
不依赖 hiboot 遗留状态，这才是主线正解，也符合用户拍板的方向。

---

## 5. 建议路线（下一步，待用户确认后再动手）

1. **基线对齐**：读 `histb-mainline/patches/baseline`，确认内核版本/BASE_SHA
   （目前是 7.4；我们内核子模块是 loonpn 的 6.3-rc5）。
   决定是「把 600/910/400/500 系列补丁 backport 到我们的 6.3 树」
   还是「把内核子模块换成 histb-mainline/linux 的对应基线」。
   —— 后者更省事、且是别人验证过的组合。
2. **最小可用子集**：先只取显示相关
   （`0xx` dt-bindings 依赖 + `400-02` CRG + `500-01/02` HDMI bridge +
   `600-*` VDP/HDMI + `910-*` EC6108V9C DTS），不碰 vdec/vpss/jpeg/audio。
3. **cmdline**：保留 `console=tty0`（论坛实锤必需），去掉
   `clk_ignore_unused`（改由 CRG 驱动主动管时钟），
   `root=mmcblk0p8` 与我们的 8 分区布局保持。
4. **显存**：采用 `media_cma` reserved-memory + `no-map`，
   删掉/停用我们那个「读寄存器找地址」的 simplefb 驱动
   （或留作 fallback）。
5. **pstore 保留**（已加）：调试生命线，别丢。
6. **CI**：按 `docs/024` 的并行 job 结构，把新内核源码/补丁作为构建输入，
   产物仍走 release。
7. **验证**：刷机后看 HDMI 是否出 dmesg；
   若仍黑屏，用 `hack-7.4/990-11/12/13` 的寄存器快照工具对照下游。

---

## 5.5 刷机 / 引导链调研（次要，仅记录；用户拍板：优先显示，不纠结刷机方式）

> 用户原话：「如果别人有解决方案的话，那同时也可以参考一下他们是怎么刷机的
> …我们现有的这个社区的刷机方案可能不是最优的，虽然是一个行得通的」；
> 随后又定调：「不要太纠结刷机方式…没有的话，至少我们现在是有一个可行方案的。
> **优先解决显示问题，这个才是最重要的**」。
> → 本节只做资料留存，不改变现有方案。

### 5.5.1 histb 官方文档站（Sphinx）

`http://histb-mainline.github.io/` —— 有专门针对我们这块板的页面：
**`appendix/boards/ec6108v9c.html`**（EC6108V9C Board）。

该页面列出的关键事实：

- **USB_BOOT 触点 = J16（near power switch）**，与我们「短接触点」是同一个东西。
- 原厂（Android 16 分区）`bootargs`：
  ```
  bootcmd=mmc read 0 0x1FFBFC0 0x4B000 0x5000; bootm 0x1FFBFC0
  bootargs_1G=mem=1G mmz=ddr,0,0,400M
  bootfile="uImage"  bootdelay=0  verify=n
  ```
  分区：`1M(fastboot),4M(bootargs),16M(recovery),1M(deviceinfo),4M(baseparam),
  4M(pqparam),4M(logo),16M(fastplay),8M(misc),24M(factory),12M(kernel),
  8M(iptv_data),340M(backup),340M(cache),520M(system),-(userdata)`
  （`bootargs` 分区 **sector size 0x10000**，env Offset 0x00100000 / Size 0x00010000）
- boot log：Bootrom → DDR training → **Fastboot 3.3.0**（2016-07-07，本质是
  U-Boot 2014 fork，删了版权声明）→ HiSTBAndroidV600R001C00SPC063 →
  **Secure boot is enabled** → `getinfo ddrfree: base 0x1000000 size 0x3F000000`
  → `Press Ctrl+C to stop autoboot` → uImage @ 0x3e08000 / ramdisk @ 0x4e00000,
  Load Address 0x02000000。
- fastboot 命令全集里有：`fatload / fatls / fatinfo`、`mmc / mmcinfo`、
  `tftp / bootp / rarpboot`、`usb / usbboot`、`setenv / saveenv / printenv`、
  `go / bootm / bootimg`、`loadb/loady/uploadx`（串口）、`getinfo ddrfree`、
  `crc32`、`unzip` 等。

### 5.5.2 引导链（`software/bootrom/bootstrap.html`、`software/vendor/fastboot.html`）

**Bootrom 层两条 bootstrap：**
1. **USB bootstrap**：`USB_BOOT` 短接 GND（Schmitt triggered，板子页面标 J16）。
   U 盘 **FAT32 分区根目录放 `fastboot.bin`**，bootrom 从 U 盘加载 bootloader 到
   RAM 启动（**不写 flash**）；找不到就去内部 eMMC/NAND。
   文档原话："You can wire the test pin to GND permanently for easy debug."
2. **Serial bootstrap**：HiTool 的 `libbootrom`，或开源替代 **HiLoot**
   （`github.com/histb-mainline/hiloot`，`hiloot.py <fastboot.bin> [chipprops]`，
   走 USB-TTL 串口，上传 bootloader 后拿到 U-Boot 命令行）。

**Vendor Fastboot 的 USB boot 序列（与我们最相关）：**
```
若 USB_BOOT 拉低 → 尝试从 U 盘读两个文件：
   bootargs.bin   (U-Boot env file, sector size 0x10000)
   recovery.img   (Android bootimg 或 uImage)
否则 → 从 eMMC/NAND 读 bootimg/uImage
```
- 即：**U 盘 + 顶层 `bootargs.bin` 这个机制是 vendor fastboot 原生支持的**，
  我们一直在用；社区包只是把 `bootcmd` 写成 `fatload + mmc write` 来刷 eMMC。
- 文档给出的 `bootargs.bin` 制作方法：`libubootenv-tool` 的
  `fw_printenv/fw_setenv -c fw_env.config`（`bootargs.bin 0 0x10000 0x10000`）
  → 与我们的 `scripts/mkbootargs.py`（CRC32 env，64KB）同类，可互相校验。
- 文档给出的 uImage 制作：`cat zImage dtb > zImage-dtb` +
  `mkimage -A arm -O linux -T kernel -C none -a 0x2000000 -e 0x2000000`
  → **与 `scripts/build-kernel.sh` 的做法完全一致**（LOADADDR=0x2000000），独立印证。

### 5.5.3 「更优刷机方案」是否存在？结论：对我们不可用 / 不值得

| 候选 | 内容 | 对我们是否可用 |
|---|---|---|
| **U 盘直接 boot 内核、不写 eMMC** | 把顶层 `bootargs.bin` 的 `bootcmd` 改成 `fatload usb 0 ... uImage; bootm ...`，试内核不用反复刷写、不会刷砖 | **理论可行**（fastboot 原生支持 fatload + bootm），是唯一真正的改进点；但需改刷机脚本、且**依然看不到日志**（无串口），收益有限 → 仅记录，**不做** |
| HiLoot / Serial bootstrap | 串口上传 bootloader + U-Boot 命令行 + tftp 调试 | ❌ **本机无串口硬件**（已确认），无法使用 |
| `histb-stage1` + TF-A | 从 HiSTB fastboot 交接到 upstream TF-A BL31，PSCI/SMP | ❌ README 明确只做了 **hi3798mv200h（aarch64 A53）**，"hi3798mv200h is the only chip configuration"；**mv100 是 32-bit Cortex-A7，不在其列** |
| 主线 U-Boot | 文档站 `software/opensource/u-boot.html` 是**占位页**（只有一句 "community-driven open-source bootloader U-Boot"），无实质内容 | ❌ 无可用成果 |
| HiTool | 厂方 Windows 烧录工具，需串口/USB + ChipProperties | ❌ 无串口、无 Windows 环境 |

→ **结论：现有「U 盘 + 顶层 bootargs.bin + 短接触点」方案可行为真，
且因无串口 + 32-bit，上游那些更现代的引导链在我们这块板上用不上。
刷机方式不是瓶颈；瓶颈是内核与显示驱动。按用户拍板，聚焦显示。**

### 5.5.4 HiLoot 仓库里仍有用的小工具（记录备用）

`github.com/histb-mainline/hiloot`：
- `hiloot.py` — 串口 bootstrap（我们用不上）
- `bootimg.py <fastboot.bin> <bootparm-ver>` — 解析/拆分/裁剪 fastboot.bin
- `hireg.py` — 显示/转换 HiSTB bootrom `.reg`/`.ini` 寄存器文件
  （我们 `backup_stock/` 里的 DDR reg 文件可用它看）
- **`ubootenv.py <bootargs.bin>`** — 显示/编译 U-Boot env 文件，
  `fw_printenv/fw_setenv` 的更宽松替代 → **可用来交叉校验我们的
  `mkbootargs.py` 生成的 bootargs.bin 格式**，值得哪天验证一次。

---

## 6. 资料链接清单（防遗忘）

| 主题 | URL |
|---|---|
| pmOS Mainlining | https://wiki.postmarketos.org/wiki/Mainlining |
| pmOS Qualcomm mainline porting（simplefb/面板生成/对比 DSI 命令） | https://wiki.postmarketos.org/wiki/Qualcomm_mainline_porting |
| pmOS Mainlining Guide | https://wiki.postmarketos.org/wiki/Mainlining_Guide |
| pmOS SDM845 Mainlining（display clocks disabled / no-map / simplefb DTS） | https://wiki.postmarketos.org/wiki/SDM845_Mainlining |
| pmOS downstream kernel 打包 | https://wiki.postmarketos.org/wiki/Porting_to_a_new_device/Kernel_package/Downstream |
| mainlining.dev 启动主线内核 | https://mainlining.dev/2021/03/02/booting-mainline-kernel/ |
| Xperia 5 II 主线实战（Trojan Horse panel） | https://github.com/terminal-index/pdx206-mainline |
| SoMainline/MainlineAndroidPorting | https://github.com/SoMainline/MainlineAndroidPorting |
| **histb 论坛：Linux 7.3 mv100 HDMI 成功点亮** | https://bbs.histb.com/d/4770/6 |
| **histb-mainline 组织** | https://github.com/histb-mainline |
| **histb-mainline/linux**（主线内核 fork） | https://github.com/histb-mainline/linux |
| **histb-mainline/patches**（quilt 补丁集，含 600/910） | https://github.com/histb-mainline/patches |
| 预编译产物（论坛给的 Telegram 频道） | https://t.me/empstorage |
| histb 论坛汇总帖（实验硬件就是 EC6108V9C，基于 7.3，HDMI 能工作） | https://bbs.histb.com/d/4805 |
| **histb 官方文档站** | http://histb-mainline.github.io/ |
| **EC6108V9C 板子页（USB_BOOT=J16 / bootargs / Flash layout / boot log / 命令全集）** | http://histb-mainline.github.io/appendix/boards/ec6108v9c.html |
| bootstrap（USB_BOOT / serial 协议） | http://histb-mainline.github.io/software/bootrom/bootstrap.html |
| vendor Fastboot（USB boot 序列、bootargs.bin、uImage 制作） | http://histb-mainline.github.io/software/vendor/fastboot.html |
| Mainline U-Boot 页（占位，无内容） | http://histb-mainline.github.io/software/opensource/u-boot.html |
| Installation 页（占位） | http://histb-mainline.github.io/installation/index.html |
| histb-stage1（仅 mv200h/aarch64，我们不适用） | https://github.com/histb-mainline/histb-stage1 |
| HiLoot（串口 bootstrap + ubootenv.py 等工具） | https://github.com/histb-mainline/hiloot |
| HiSTB SDK（我们已在用） | https://github.com/JasonFreeLab/HiSTBLinuxV100R005C00SPC060 |
| 同 SoC 另一个踩坑记录（"No HDMI Output"） | https://gitlab.com/TheuTrich/stuffs-with-hi3798mv100-board |
| 本地策略参考仓库 | 另一台设备的 Debian 主线移植工程（本地私有，未入库，仅借鉴策略） |

本地已存资料：
- `TMP/histb-ref/` —— 4 个关键补丁原文（910-02 板级 DTS、910-03 VPSS、
  600-17 HDMI 发送器、600-18 video path）
- `TMP/histb-pending.json` / `TMP/histb-hack.json` —— 154 + 23 个补丁完整清单
- `docs/021`/`022`/`023`/`024` —— 本仓库此前的驱动移植设计与逆向分析

---

## 7. 与既有文档的关系

- `docs/021`：路线决策（改驱动移植）→ 本文给出**具体可复用的上游成果**
- `docs/022`：两阶段方案 → 本文证明第二阶段（自己初始化 HDMI）**上游已实现**
- `docs/023`：原厂 recovery 逆向 + VO 寄存器偏移 → 与 `910-02` 的 `VO_G0_ADDR`
  注释**独立交叉印证**
- `docs/024`：启动/显示链路审查 → 本文解释了 simplefb 路线为何不稳

---

## 8. 评估：把 histb 7.4 的显示补丁反向移植到当前 6.3 内核？

**问题**：既然 histb-mainline 已经把 mv100 HDMI 做进主线，能否只把那几个
显示补丁搬到我们现有的 6.3-rc5 内核上，比整套换 7.4 省事？

**结论：不会更省事，反而更重。** 逐项核对（对象 = `third_party/linux-hi3798mv100`
的 6.3-rc5 树）：

| 依赖 | 6.3 现状 | 后果 |
| --- | --- | --- |
| `DRM_CLIENT_SELECTION` | **不存在** | 600-17 的 `select` 直接失效，需先补该 Kconfig 或改写驱动 |
| `DRM_BRIDGE_CONNECTOR` | **不存在** | 同上，bridge connector helper 是 7.x 新增 |
| `DRM_DISPLAY_HELPER` / `DRM_GEM_DMA_HELPER` / `DRM_KMS_HELPER` | 存在 | 这三项没问题 |
| `drivers/gpu/drm/histb/` | **整个目录不存在** | 要搬 VDP2 的 plane/CRTC/encoder 全套，不是一两个文件 |
| `drivers/gpu/drm/bridge/hi3798mv100-hdmi.c` | **不存在** | 见下条 |
| 板级 DTS 引用的 `vpss` / `vdec` / `jpgd` / `media_cma` / `vdp` / `hdmi` | **全部不存在** | 要先搬一批 SoC dtsi 补丁，`910-03` 只是其中一个小补丁 |

几个容易踩的坑：

1. **mv100 用的是外挂 sii9134 transmitter，不是 on-chip HDMI**。`600-17` 新增的
   `histb-hdmi.c` 是 mv200 的片内发送器；我们板子对应的是
   `drivers/gpu/drm/bridge/hi3798mv100-hdmi.c`，而 `600-18` 只是在**该文件之上**
   打补丁（改 `VIDEO_PATH_CTRL` 与按 die revision 写 PHY 0x09）。这个文件的
   创建补丁不在本地已存的 4 个补丁里，得先从 series 补齐。
2. **补丁不是独立可挑的几个**。`pending-7.4` 共 154 个，显示链路横跨
   `600-xx`（DRM）与 `910-xx`（DTS），且互相依赖；只挑 600-17/18/910-02/03
   会缺 plane 驱动、clock/reset binding、media CMA 等前置件。
3. **等于把 hiboot 已完成的初始化重做一遍**。`600-18` 处理的
   "video path 默认关闭 + PHY 按 die revision 配置"正是 bootloader 已经做好的
   事——用户刷机后能看到 hiboot 画出的 "Debian Linux" logo，就是 VO / HDMI TX /
   PHY 全部就绪的直接证据。从零起一套 KMS 反而要重新点亮这些寄存器。

### 更省力的现成路线

- **绿带启动标记**（`docs/024` §6.1，已实现）：直接往 hiboot 留下的 framebuffer
  写像素，证明内核活着，不碰任何 DRM/VO 寄存器。
- **simplefb 交接**（`hi3798mv100-hdmi-console.c`，已实现）：把同一块显存注册成
  `simple-framebuffer` 让 fbcon 打日志，同样不需要 KMS。
- 若刷本版后**绿带出现但没有文字**，说明内核活着、显存地址也对，剩下的只是
  `fbcon` / `simplefb` 绑定问题（很可能是显存没用 `no-map` 保留 —— workflow
  已有 `fb_base` 输入可开），修这个比移植整套 DRM 小一两个数量级。
- 若**绿带都没出现**，问题在内核启动本身（p6 / DTB / `mem=`），此时搬任何显示
  驱动都不会让屏幕亮起来。

### 什么时候才值得整套换 7.4

只有当「内核能稳定启动 + simplefb 路线无法满足需求（要 KMS 热插拔、多分辨率、
Wayland、真正由内核驱动 HDMI）」时才划算。在那之前，整套迁移的成本高于收益，
且用户已明确要求先出可刷产物、暂缓维护（见 `docs/024` §6 与 `docs/026` §3）。
