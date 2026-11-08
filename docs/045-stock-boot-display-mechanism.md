# 045 — 原厂通电即显示的机制逆向与「刷机阶段即时显示进度」可复用路径

> 2026-11-08。用户新方向：原厂 Android **通电后立即显示画面**，说明某个引导程序能在极早期点亮
> HDMI/VO；目标是为「刷机/引导过程中即时显示进度条/文字」找到**可复用机制**（用户明确排除 pstore：
> 刷前刷后都要有正常系统，太复杂）。
>
> 本轮用 `docs/033 §2` REA 规范，对**原厂 16 分区备份**做只读静态逆向；重点是 `docs/031`/`037`
> 查过的**社区 539 KB 构建**之外、单独重新查**原厂 1 MiB / 2016 构建**的 p1 hiboot。
>
> 相关（部分在 `mainline-porting` 分支，本轮经只读 `git show` 交叉核对）：`docs/023`（recovery 显示）、
> `docs/027`（整机备份静态分析 §4.7/§4.8）、`docs/031`/`037`（社区 hiboot 负结果）、
> `docs/036`（刷机执行者）、`docs/038`（BootROM USB bootstrap / histb 板子页 boot log）、
> `docs/039`（社区两张 logo 机制）、`docs/040`（Linux 写 `/dev/fb0` 实证）、`docs/043`（6.3 simplefb）。

---

## 0. 结论先行

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| 1 | **原厂 p1 显示初始化调用点可达吗**？ | **不可达（本轮方法范围内）**。`PRODUCT_DisplayInit`/`Logo_Main`/`HI_ADP_DispInit`/`HDMI_Display`/`higo/*`/`OPTM_VDP_GFX_*` 等串在 1 MiB 镜像里**确实存在且比社区版多 97 条**，但全文件反汇编（262,144 指令）、任意对齐指针字、`ldr[pc]` 字面量、`add/sub pc`、movw/movt、bl 调用图、命令表、MMIO 常量扫描后，**这些串 0 引用、串簇内 0 个函数序言、44 条命令无显示命令、p1 内无 VO/HDMI MMIO 常量**。给负面边界，标 `[未知]`；**不编造地址**。与社区 539 KB 版不同点是「多了显示模块字符串与 DDR 训练 blob」，但**两版都无法静态定位可达函数体**。 | [观察] + [未知] |
| 2 | **「通电立即显示」的执行者与阶段**？ | **[推断]** 执行者是 **p1 fastboot 内、早于 `bootcmd`/内核加载的显示初始化**（不是 U-Boot 命令、不是内核）。文档级 boot log 显示 GFX 模块（`higo/adp_gfx.c`）在 fastboot 阶段、读 RSA key / `boot from kernel` 之前就打印错误；p1 内含其格式串 `=====FILE: %s, LINE: %d, Ret:%x` 与源码路径名。读的 logo 来自 **p7 logo 分区**（`LOGO_TABLE` 容器），显示参数来自 **p5 baseparam**（时序全 0 → EDID 运行时读）。时间线见 §2.3。 | [推断] + [观察] |
| 3 | **p7 logo 分区结构 / 是否多帧动画**？ | **只有 1 张图**。`###\0` + `table_len=0x7c` + `LOGO_TABLE` + `LOGO_KEY_FLAG=1` + `LOGO_KEY_LEN=0x2E820`(190,496) + **单张 1920×1080 JPEG @0x2000..0x30820**（`sips` 复核 1920×1080）。**无多帧/进度序列**：gzip/BMP/PNG 魔数命中全是假阳性（40 次 `inflate` 全失败、`BM` 头解出荒谬尺寸）；0x32000..0xBF688 为高熵无结构数据，性质 `[未知]`，不据此推断第二张图。→ **LOGO_TABLE 不能拿来做进度条/动画**。 | [观察] + [未知] |
| 4 | **p3 recovery 进度 UI 能否照搬**？ | **能，且是现成素材**。`progress_empty`/`progress_fill`(474×14 进度条)、`indeterminate01-06`(252×7，6 帧不确定进度)、`icon_installing_overlay01-07`(110×132，7 帧)、`icon_installing`(580×120)、`installing_text` 等构成一套完整安装 UI。`/sbin/recovery` 是 ELF32 ARM，`.rodata` 里有 `/dev/graphics/fb0`、`/res/images/%s.png`、`framebuffer: fd %d (%d x %d)`、`indeterminate%02d` 等；**radare2 `axt` + capstone Thumb-2 互验**定位到 `fcn.0x26050` 用 `ldr r2,[pc,#0x204]`+`add r2,pc` 取到 `/res/images/%s.png` 的 VA `0x637E4`。但 UI **依赖内核已注册 fb0**（`docs/023 §3`、`docs/040`），且 7 张 `icon_installing_overlay*` 在本二进制里**范围内未检索到按名引用**（默认 AOSP 残留资源）。 | [观察] + [推断] |
| 5 | **刷机阶段显示进度最可行的路径**？ | **方案 A（推荐）＝照搬 p3 recovery 的「Linux 用户态写 fb0 进度 UI」**：用一个已具备显示栈的内核启动精简 ramdisk，刷机动作与进度绘制同在该用户态进程内完成（进度条/6 帧 spinner/文字照抄 p3 素材）。**实证基础**：§4 的 p3 UI + `docs/023 §3` fb0 机制 + `docs/040` 真机写 `/dev/fb0` 稳定上屏。**不动 p1 二进制、不用 pstore**。次选方案 B＝`docs/039 §4.2` 的「中间系统二次写 p5 + reboot」阶段图（离散、每阶段一次重启）。**不可行**：改 p1 hiboot（§1 负结果 + `docs/037` NO-GO）、靠 p7 LOGO_TABLE 多图切换（§3 否证）。 | [观察] + [推断] |

---

## 1. 对象、工具、方法（复现基线，REA §2 第 7 条）

**[观察]** 本轮只读分析对象（路径均为仓库内相对路径）：

| 对象 | 大小 | SHA-256 | 说明 |
|---|---|---|---|
| `TMP/stock-rom-research/extracted/p01_fastboot.img` | 1,048,576 B | `bac0be9ff5926de1c813668216977c85e1903ceb3e69b83e5a7ffb2156b0c073` | 原厂 p1 hiboot（Fastboot `3.3.0-00786`，2016 构建） |
| `TMP/stock-rom-research/extracted/p07_logo.img` | 4,194,304 B | `cfc5db33166cbdf72577690b2d661647524c5138cf012ebdca52b2ed9f178ae6` | logo 分区 |
| `TMP/stock-rom-research/extracted/p05_baseparam.img` | 4,194,304 B | `819fccdde59672a875cd6898f03f262d794860d25928478c839fda33ba8f8cdb` | 显示参数分区 |
| `TMP/stock-rom-research/extracted/p03_recovery.img` | 16,777,216 B | `dcb4a24778adbc01241cafb08db6e0319177a7dd4f840df15f7e098b1c589074` | recovery 分区（含 ramdisk UI 资源） |
| `TMP/stock-rom-research/extracted/p03__sbin__recovery` | 445,036 B | ELF32 ARM | recovery 主程序 |
| `TMP/community-restore/fastboot.bin` | 539,264 B | `fd5b4ac6ce4d50e8a127957dc86a2d2fa503d150db2abca014033ad4e7de7f0b` | 社区 539 KB 对照 |
| `TMP/stock-rom-research/extracted/p02_bootargs.img` | 4,194,304 B | — | 原厂 env（前 64 KiB CRC `0x792AC979` 校验通过） |

工具：**capstone 5.0.7**（主，`CS_ARCH_ARM / CS_MODE_ARM|LITTLE_ENDIAN`，**`skipdata=True` 全文件覆盖**；对 recovery `.text` 另用 `CS_MODE_THUMB`），**radare2 6.2.4**（独立 oracle：`axt` / `pd` / `pxw` / `/x`），Python 3.14，macOS `sips`（JPEG 尺寸复核）。链接基址 **`0x00C00000`**（本轮以 1,706 个字符串指针投票重新验证，次优仅 142；与 `docs/031 §1.3` 一致）。

> **[观察] 方法纠错（重要）**：仓库内既有的 `TMP/stock-rom-research/hiboot-disasm/scan.py` 对 p1 做过浅扫并报「display strings 0 literal xrefs」，但**它没有设 `md.skipdata = True`**——按 `docs/031 §1.3`/`docs/033 §2` 的已知坑，capstone 会在首个非法字（约 `0x40`）处停止，只解出约 16 条指令，该「0 引用」结论**不成立**。本轮用 `skipdata=True` 重做，才得到下列可信的覆盖边界。

---

## 2. Q1 — 原厂 p1 显示初始化调用点可达吗

### 2.1 原厂 1 MiB 与社区 539 KB 确实不同

**[观察]** 逐字节字符串集合差：原厂 2,491 串 / 社区 2,662 串，**原厂独有 710 串**，其中显示相关 **97 条**是社区版完全没有的：

```
=====FILE: %s, LINE: %d, Ret:%x        higo/adp_gfx.c        higo/hi_go_bliter.c
higo/hi_go_gdev.c / hi_go_surface.c / hi_go_decoder.c / higo_memory.c / ...
PRODUCT_DisplayInit err! Ret = %x   HI_ADP_DispInit err! Ret = %x
HI_ADP_GrcCreate err! Ret = %x     HI_LOGO_DecImg err! Ret = %x
HI_PDM_GetGrcParam err! Ret = %x   HI_UNF_DISP_Init err! Ret = %x
boot logo show!!!                  ========DispResetHardware=======
OPTM_VDP_GFX_SetLayerAddrEX / SetLayerStride / SetLayerEnable / SetRegUp / ...
Error,OPTM_VDP_GP_Set* ...         HIFB_Fb%d_Clut / HIFB_GfxWbc2 / HIFB_ZmeCoef
fastapp_entry / swfastboot_flash_write / swfastboot_flash_read
coherent_pool=2M mem=1G ... initrd=0x2500000,0x1300000 mmz=ddr,0,0,256M root=/dev/ram ...
```

`=====FILE: %s, LINE: %d, Ret:%x` 正是 histb 板子页 boot log 里 `=====FILE: higo/adp_gfx.c, LINE: 150, Ret:b0038002` 那条输出的**格式串**；`higo/adp_gfx.c` / `higo/hi_go_bliter.c` 也在此。→ **[推断]** 原厂 1 MiB 构建**链接进了 higo/GFX/DISP/VDP 显示模块**（`docs/038` 记录的板子页 boot log 亦显示该模块在 fastboot 阶段运行）。这是相对 `docs/031`/`037` 社区负结果的**实质差异**：原厂镜像里显示相关材料多得多。

**[观察]** 结构差异还包括：p1 尾部 `0x94000..0x96FC9` 有一段**独立的 DDR 训练代码 blob**（29 个函数序言、`ddr_*` 函数名与 `PHY[%x]` 日志串），末 430,135 B 为全 0 填充；社区版整体 539,264 B 无此尾部。

### 2.2 全文件可达性扫描：负结果（含 radare2 互验）

**[观察]** 对 `p01_fastboot.img` 做 `BASE=0x00C00000` 的全文件扫描，覆盖范围：

| 方法 | 覆盖结果 |
|---|---|
| kallsyms / ELF 符号表 | `kallsyms` / `kallsyms_addresses` / `kallsyms_num_syms` / `kallsyms_names` / `kallsyms_token_table` / `__ksymtab_` / `__kstrtab_` / `\x7fELF` 全部 **0 命中**（U-Boot 裸镜像，无内核式符号表）→ 按任务要求改用「函数序言 + 调用图」。 |
| capstone ARM 全文件（skipdata） | **262,144 条指令**、**1,359 个函数序言**、**1,399 个 bl 目标**、**4,668 个字面量池**；代码区 `0x0..0x78000` 有 **1,321** 个序言（16 KB 桶密度均匀），`0x94000` 桶另有 29 个（DDR blob）。 |
| 任意对齐 32-bit 指针字 | 对 30+ 个显示函数名/日志串逐一搜索 `BASE+off` 的 4 字节小端值，**全部 0 命中**（含 ±0x20 窗口，仅 `0x28a18` 一个落在 `PRODUCT_DisplayInit` 附近，实为指向 zModem 错误串表 `0x00c7935c` 的假阳性）。 |
| `ldr [pc,#imm]` 字面量 | 4,668 个字面量池中，**无任何一条**装入上述显示串 VA（对照：`bootcmd`/`Press Ctrl+C`/`## Booting kernel` 等 U-Boot 通用串各有 1 条指针命中）。引用串偏移分布：0x78000 桶 23、0x7C000 桶 4、0x80000 桶 33、**0x84000–0x8C000 桶 1,379**（绝大多数），显示串所在的 0x79000–0x83000 几乎不被引用。 |
| `add/sub pc,#imm`（ADR） | 全文件 `adr` 助记符 **0 条**；`add/sub ... pc` 落进显示串簇（0x79370–0x79FA0、0x81B50–0x81C80）**0 条**。 |
| movw/movt 常量构造 | 构成显示串 VA 的 movw/movt 对 **0 组**。 |
| 第二链接基址 | 以全部显示串偏移做 `w - s` 直方图，**无第二支配基址**（`0x00C00000` 1,706 票，次优为噪声级 142 票以下）。 |
| 显示串簇内函数序言 | `0x79370..0x79FA0` **0 个**、`0x81B50..0x81C80` **0 个** → 该区间是纯 rodata，无相邻函数体。 |
| `cmd_tbl_s` 命令表 | **44 条**（`go/reset/bootm/ddr/fatload/fatls/getinfo/help/loadb/loady/uploadx/mmc/nand/nboot/tftp/usbboot/version/otp*` …），**`logo`/`disp`/`hdmi` 显示命令 0 条**；radare2 `pxw @ 0x00c93a2c` 复核 `go` 记录结构（name/maxargs/repeatable/cmd/usage/help）。 |
| VO/HDMI MMIO 常量 | `0xf8cc0000`、`0xf8ce0000`、`0xf8ce1800`、`0x08ce0000`、`0x08cc0000`、`0xfdcc0000` 在 p1 全文件 **0 命中**；头部 `0x0..0x3000` 只有 `0xf8a2xxxx`/`0xf8a3xxxx`/`0xf8000xxx` 系统/DDR 寄存器对（396 个），**无 VO/HDMI 寄存器**。 |
| 压缩载荷假设 | p1 无 gzip/xz/zlib 魔数、最高 4 KB 块熵 6.84、无 `Compressed-boot` 串 → **不存在自解压的第二段代码**（板子页 boot log 的 `Compressed-boot v1.0.0` 属另一个构建 `3.3.0-00709`，本镜像为 `3.3.0-00786`）。 |

**[观察] radare2 6.2.4 独立 oracle**：`/x` 搜索 `7c93c700`（`PRODUCT_DisplayInit` VA 小端）、`9093c700`（`Logo_Main`）、`d01bc800`（`LOGO_TABLE`）、`5cf507c0`（`boot logo show!!!`）、`400480c0`（`=====FILE`）**均 0 命中**；`pxw @ 0x00c23468` 复核 main_loop 字面量池（`0x00c8b957`=`bootcmd`、`0x00c8b993`=`Press Ctrl+C`）与 capstone 一致。→ 两种工具**互验一致**。

### 2.3 Q1 判定与边界

> **[观察] 负面边界（严格按 REA §2 第 2 条）**：在「4 份镜像 / ARM A32 / `0x00C00000` / capstone skipdata 全文件 + radare2 oracle / 上述 10 类交叉引用」范围内，**未检索到** `PRODUCT_DisplayInit → Logo_Main → HI_GFX_ShowLogo`/`HDMI_Display` 的可达函数体或真实调用点；**未检索到**显示命令、显示函数名/日志串的任何指针或字面量引用、VO/HDMI MMIO 常量。给出的是**方法覆盖边界**，**不是「显示不存在」**。
>
> **[未知]**：显示初始化函数体 VA、`PRODUCT_DisplayInit`/`Logo_Main` 的实现地址、`HI_DRV_HDMI_*`/`TX_PHY_*` 寄存器写入序列在 p1 中的位置。
>
> **[存疑] 合理解释（不下定论）**：`0x7937C..0x7A7DC` 是一段 **20 字节定长的函数名表**（`HI_UNF_HDMI_*`/`DISP_*`/`PDM_*`/`HI_UNF_OTP_*`/`fastapp_entry`/`swfastboot_flash_*`，共 130+ 条，`docs/027 §4.8` 与 `docs/031` 也见过），`0x7F5xx..0x81Cxx` 是显示模块日志/PDM 键串（含 `logo`/`logobak`/`LOGO_KEY_*`）。二者**整体无静态引用**最可能是「链接期保留的导出符号名/源码路径表 + 实现以运行时加载/重定位的模块（fastapp/fastplay）提供」，或该模块在本构建里被裁掉而只剩 rodata。`p08_fastplay` 分区在本备份中全 0、p1 含 `fastapp_entry` 与一条 `initrd=... root=/dev/ram mmz=ddr,0,0,256M` 的 ramdisk cmdline，均支持这一 [推断]，但**本轮无运行时证据，不据此断言**。
>
> **[观察] 与社区 539 KB 的对比结论**：原厂 1 MiB 版**确实不同**（多 97 条显示模块串、higo/GFX/DISP/VDP 日志格式串、DDR 训练 blob）；但 `docs/031`/`037` 对社区的「命令表无显示命令、显示串孤立 rodata、无可达显示函数体」负结果，**在原厂 1 MiB 版上同样成立**——即「更多字符串」**没有**转化为「静态可定位的调用链」。
>
> **[推断] 关键张力**：`docs/039` 实证社区 hiboot 在**正常开机路径**会画 p5 logo，而两版 fastboot 都定位不到显示函数体 → 说明「显示能力存在」与「能否用字符串交叉引用定位」是两件事；本轮的负结果**不推翻** `docs/039`，只说明**不能靠改 p1 二进制来复用这条链**（§5.3）。

---

## 3. Q2 — 「通电立即显示」的执行者与阶段

### 3.1 二进制与 env 侧证据

**[观察]** p1 内 boot-flow 串：`Press Ctrl+C to stop autoboot`@`0x8B993`（指针 @`0x2347C`）、`bootcmd`@`0x8B957`（指针 @`0x23468`）、`## Booting kernel`@`0x87794`（指针 @`0x17EA0`）、`Boot Media:    %s`@`0x8CEE2`（指针 @`0x6B1B4`）→ main_loop/自动开机代码在 `0x23000` 附近，**无显示命令**（§2.2 命令表 44 条）。

**[观察]** 原厂 p02 env（前 64 KiB CRC `0x792AC979` 通过）：`bootcmd=mmc read 0 0x1FFBFC0 0x4B000 0x5000; bootm 0x1FFBFC0`，`bootdelay=0`，`verify=n`，`bootfile="uImage"`，`mmz=ddr,0,0,400M`。**bootcmd 里没有任何显示动作** → 显示不经过 env/命令层，是 fastboot 主流程内隐式完成的 [推断]。

**[观察]** p1 含 `=====FILE: %s, LINE: %d, Ret:%x`@`0x80440`、`higo/adp_gfx.c`@`0x835BC`、`higo/hi_go_bliter.c`@`0x80464`、`boot logo show!!!`@`0x7F65C`、`PRODUCT_DisplayInit err! Ret = %x`@`0x7F5B4`；与 histb 文档站 EC6108V9C 板子页 boot log 里的 `=====FILE: higo/adp_gfx.c, LINE: 150, Ret:b0038002` / `=====FILE: higo/hi_go_bliter.c, LINE: 149, Ret:b0038002` 输出**格式与源码名逐字对应**（`docs/038 §5` 已核实该页面及 RST 源）。→ **[推断]** 原厂 fastboot 在开机早期确实运行 higo/GFX 初始化。

### 3.2 读哪个分区

**[观察]** p7 `LOGO_TABLE` 是单张 1920×1080 JPEG 容器（§4 完整解析）；p5 `baseparam` 的 `BASE_TABLE_DISP0` 全部 `TIMING_*`=0、`VIRSCW=1280`/`VIRSCH=720`、`HDMI0=(9,1,0)`、`BASE_TABLE_HDMI` 的 EDID 长度 0 / 512 B 全 0（`docs/027 §4.7`）→ **[推断]** 显示时序运行时由 sink EDID 决定，logo 图数据来自 p7，显示参数来自 p5。p1 里 `logo`/`logobak`/`LOGO_KEY_FLAG`/`LOGO_KEY_LEN` 串位于 `0x81B64..0x81BEC`，属 PDM 参数键（`docs/031 §2.4` 同判），**不是 U-Boot 命令**。

### 3.3 时间线（`docs/038` 文档级 boot log + 本轮静态证据拼合）

```
[观察·文档] Bootrom start → Boot from eMMC → Initializing DDR ... OK → DDR training ... OK
            → Starting fastboot ...
[观察·二进制] p1 首阶段串 System startup / Reg Version: v1.1.0 / Reg Name: <.reg 文件名>
              / Relocate Boot to DDR / Jump to DDR   (@0x24BC/0x251A/0x246C/0x2498)
              与板子页 Reg Name: hi3798mdmo1g_..._emmc.reg 逐字一致 (B4 交叉验证)
[观察·文档] Fastboot 3.3.0 版本打印 → Boot Media: eMMC / DDR Size: 1GB → MMC/SD 初始化
            → Boot Env on eMMC → SDK Version 打印
[推断·显示] ★ GFX/higo 初始化（=====FILE: higo/adp_gfx.c / hi_go_bliter.c 日志）
            → 读 p5 baseparam 显示参数 + 读 p7 LOGO_TABLE 图 → 点亮 HDMI/VO 并画 logo
            （p1 有 boot logo show!!! / PRODUCT_DisplayInit err! / HI_ADP_DispInit err! 等串）
[观察·文档] Security Begin Read RSA Key! → Secure boot is enabled → ... → ****** boot from kernel...********
            → kernel @ 3e08000 / ramdisk @ 4e00000 → Starting kernel ...
```

→ **[推断]** 「通电立即显示」发生在 **BootROM 加载 p1 → p1 fastboot 自身早期初始化（board_init_r/main_loop 之前或之初）**，**早于**读 RSA key、`bootm` 内核；**不是** Linux 内核画的，也不是 env/命令触发。p1 静态无法定位该初始化函数体（§2），故此时间线的显示环节标注为 [推断]，待真机验证。

**[存疑] 保留**：① 板子页 boot log 属另一构建（`3.3.0-00709`），本机 `3.3.0-00786` 是否逐字同源未证；② `docs/039 §4.2` 指出社区「写 p5 → 之后开机由 hiboot 画」，与「刷机链执行期间不刷新画面」并存，本轮未在本机验证显示刷新时机；③ 短接态（`docs/038` 模型 B）与正常开机态的显示分支差异未做运行时区分。

---

## 4. Q3 — p7 logo 分区 `LOGO_TABLE` 完整解析

### 4.1 表结构（radare2 `pxw` 与 Python 互验）

**[观察]** `p07_logo.img`（SHA-256 `cfc5db33…`，4 MiB）头部：

| 偏移 | 值 | 语义 |
|---|---|---|
| `0x00` | `23 23 23 00` (`###\0`) | 容器魔数 |
| `0x04` | `0x0000007C` | 表长度 124 B |
| `0x08` | `LOGO_TABLE` | 表名（32 B 字段） |
| `0x28` | `0x00000050` | 字段（未定名，[未知]） |
| `0x2C` | `LOGO_KEY_FLAG` | 键名（32 B 字段） |
| `0x4C` | `0x00000004` | 值长度 4 B |
| `0x50` | `0x00000001` | **FLAG = 1**（图有效/存在） |
| `0x54` | `LOGO_KEY_LEN` | 键名（32 B 字段） |
| `0x74` | `0x00000004` | 值长度 4 B |
| `0x78` | `0x0002E820` | **LEN = 190,496 B**（图数据字节数） |
| `0x7C` | `0` | 表结束 |
| `0x2000` | `FF D8 FF` | 唯一 JPEG 起点 |

结构即「32 B 键名 + 4 B 值长度 + 值」的定长表；`LOGO_KEY_LEN` 恰好等于下面 JPEG 的字节数。`docs/039 §2` 对社区 `logo.img` 的字段布局与此**完全一致**（那里 LEN 分别为 54,221 / 238,426），说明是同一容器格式、不同图片。

### 4.2 图片内容：只有一张，无动画/进度序列

**[观察]** 结构化验证（按 SOF/EOI/PNG chunk/BMP DIB，不靠魔数猜，`docs/033 §2` 第 3 条）：

- **唯一有效 JPEG**：`@0x2000`，SOF 解出 **1920×1080**，EOI `@0x30820`，**大小 190,496 B = `LOGO_KEY_LEN`**，SHA-256 `f481d54fc0621543b9f47ee5e4194cc4bd2494d9b3f3a2f361d9a8e39e89752e`；`sips` 复核 1920×1080。已提取到 `TMP/stock-rom-research/logo-extract/logo_00_2000_1920x1080.jpg`。
- **PNG 0 张**、**有效 BMP 0 张**（11 处 `BM` 的 DIB/宽高全部为乱码，如 `dib=4041189344`、`w=-1096879796`）、**有效 gzip 0 个**（40 个 `1f 8b` 候选逐一 `zlib.decompressobj` 全部失败）；`docs/027 §4.7` / 本轮 format-aware 预扫所记「多处 gzip/BMP 魔数 → 多张 logo 打包」是**魔数假阳性**。
- `0x32000..0xBF688`（579,208 B ≈ 566 KiB）为**高熵（≈7.0）、无结构数据**：27 处 `1f 8b`、9 处 `BM`、11 处 `78 9c` 全为随机命中，无 `###`/`LOGO_TABLE`/JPEG/PNG 签名，字节直方图 256 值均匀。性质 **[未知]**（可能加密/加扰数据或随机填充），**不据此推断为第二张图或动画帧**。
- 末非零字节 `0xBF688`，非零比例 0.1791；其后全 0 到 4 MiB。

→ **[观察] 判定**：`p07_logo.img` 是**单张静态开机 splash**，**不含多帧动画或进度序列**；`logobak` 键在 p7 内**范围内未检索到**（只在 p1 rodata 里作为 PDM 参数键串出现）。→ **`LOGO_TABLE` 本身不能拿来切图做进度条**（这否证了任务里「利用 LOGO_TABLE 多图切换」的候选）。提取产物：`TMP/stock-rom-research/logo-extract/`（JPEG + 512 B 表头），全部在项目内 TMP、gitignored。

---

## 5. Q4 — p3 recovery 的进度 UI 资源与用法

### 5.1 资源集合（PNG IHDR 逐一解析，含 IEND 校验）

**[观察]** `TMP/stock-rom-research/extracted/p03__res__images__*.png` 全部为合法 PNG：

| 组 | 文件 | 尺寸 / 色型 | 用途判定 |
|---|---|---|---|
| 进度条 | `progress_empty.png` / `progress_fill.png` | **474×14**, RGBA(6) | 进度条轨道 / 填充条 [观察] |
| 不确定进度 | `indeterminate01..06.png` | **252×7**, RGB(2) | **6 帧循环 spinner** [观察] |
| 安装动画 | `icon_installing_overlay01..07.png` | **110×132**, 调色板(3) | **7 帧覆盖动画** [观察] |
| 底图 | `icon_installing.png` / `icon_error.png` / `icon_nopackage.png` / `icon_sdcard_installing.png` | 580×120, RGBA | 状态底图 [观察] |
| 文字条 | `installing_text.png` 480×1898 / `erasing_text.png` 322×1601 / `no_command_text.png` 420×1601 / `error_text.png` 148×1601 | 灰度(0) | 竖排文字图 [观察] |

→ **[观察]** 这是一套**完整的 Android recovery 安装进度 UI**（进度条 + 不确定进度动画 + 安装动画 + 状态底图 + 文字），正是用户要的「进度条」现成素材。

### 5.2 `/sbin/recovery` 怎么用（反汇编级证据，radare2 + capstone 互验）

**[观察]** `p03__sbin__recovery` 为 **ELF32 ARM**（`e_machine=40`），`e_entry=0x80F8`，`.text` `0x80F8..0x5C3DC`（0x54,2E4 B）、`.rodata` `0x5F2B8..0x6F8A8`；**符号表 0 条（strip）**；`.text` 为 ARM A32 与 Thumb-2 混编、PIC/GOT 相对（入口 `ldr r3,[pc,#0x50]; add r3,pc,r3`）——这解释了「绝对指针字 0 命中」是结构使然，不是「没有引用」。

**[观察]** `.rodata` 里的 UI 资源名表（`0x590B8..0x59178`）：`icon_installing` / `icon_wipeing` / `icon_wipeing2` / `icon_error` / `progress_empty` / `progress_fill` / `icon_nopackage` / `icon_sdcard_installing` / `installing_text` / `erasing_text` / `no_command_text` / `error_text` / **`indeterminate%02d`**；另有 `/dev/graphics/fb0`@`0x6373F`、`cannot open fb0`、`failed to get fb0 info`、`failed to mmap framebuffer`、`framebuffer: fd %d (%d x %d)`、`/dev/tty0` + `KDSETMODE to KD_GRAPHICS`、`font`、`/res/images/%s.png`@`0x637E4`、`set_progress` / `ui_print`。

**[观察] 关键片段互验**：radare2 `axt @ 0x637E4`（`/res/images/%s.png`）给出 `fcn.00026050 @0x2606c add r2, pc`；capstone Thumb-2 反汇编该函数：

```
0x00026050  push.w {r4,r5,r6,r7,r8,sb,sl,fp,lr}
0x00026054  sub    sp, #0x12c
0x00026056  ldr    r2, [pc, #0x210]   ; pool@0x26268 = 0xfffffe98
0x0002605C  ldr    r1, [pc, #0x20c]   ; pool@0x2626C = 0x0004cf90
0x00026060  add    r1, pc             ; GOT 基址
0x00026068  ldr    r2, [pc, #0x204]   ; pool@0x26270 = 0x0003d774
0x0002606C  add    r2, pc             ; 0x26070 + 0x3d774 = 0x637E4 = "/res/images/%s.png"
0x0002606E  add    r0, sp, #0x24
0x0002607E  ldr    r1, [pc, #0x1f4]   ; pool@0x26274 = 0x0003970e
0x00026086  add    r1, pc
0x00026088  bl     #0x46680           ; 资源名格式化 / surface 加载链
...
```

两工具对同一 VA 的取址**一致**。→ **[推断]** 该函数是 `res_create_localized_surface`/`gr_load_surface` 一类「按 `/res/images/%s.png` 拼名并加载 PNG surface」的实现（标准 AOSP minui/RecoveryUI 结构），由 `docs/023 §3` 的 fb0 机制佐证。

**[观察]** `p03__init.rc` 有 `service recovery /sbin/recovery`、`service ueventd /sbin/ueventd`，**无 surfaceflinger/minui 独立服务**；`p03__ueventd.rc` 有 `/dev/graphics/* 0660 root graphics` 与 `/dev/tty0 0660 root system`。→ **[推断]** UI 由 `/sbin/recovery` 进程内直接 `open("/dev/graphics/fb0")` + `FBIOGET_FSCREENINFO/VSCREENINFO` + `mmap` 写显存 blit PNG（`docs/023 §3` 同结论），**自己不碰 VO 寄存器，完全依赖内核已注册 fb0**。

**[观察] 重要负结果（REA 不靠文件名推断）**：`/sbin/recovery` 全文件对 `overlay` / `icon_installing_overlay` / `overlay%02d` **范围内未检索到**（0 命中），唯一的动画格式串是 `indeterminate%02d`。→ **[推断]** 7 张 `icon_installing_overlay01-07.png` 是本构建**未引用的默认 AOSP 残留资源**；真正在用的循环动画是 **6 帧 `indeterminate01-06`**。

→ **Q4 结论**：**[观察]** p3 是一套可照搬的进度条/安装动画素材与 fb0 blit 机制；**[推断]** 照搬的前提是「有一个已初始化显示硬件、注册了 fb0 的 Linux 内核」（`docs/023 §3`、`docs/040` 的 `/dev/fb0` 写屏实证，含双缓冲需写满两帧）。**它不是 bootloader 阶段的机制**，需要 Linux 起来。

---

## 6. Q5 — 「刷机/引导阶段即时显示进度」可复用方案评估

### 6.1 方案 A（推荐，实证可做）：照搬 p3 的「Linux 用户态写 fb0 进度 UI」

| 项 | 内容 |
|---|---|
| 做法 | 用**已具备显示栈的内核**启动一个精简 ramdisk「刷机 UI 中间系统」：一个用户态进程 `open("/dev/fb0")`/`mmap`，按刷机进度绘制 **进度条（照 `progress_empty`/`progress_fill` 合成）+ 6 帧 `indeterminate` spinner + 文字条**；刷机动作（`fatload`/`mmc write` 等价物）与进度绘制在**同一进程**内推进。素材直接复用 §5.1 的 PNG。 |
| 实证基础 | **[观察]** §5 的 p3 UI 与 `/sbin/recovery` fb0 路径（含 `/res/images/%s.png` 反汇编取址）；`docs/023 §3`（fb0 几何 + blit）；`docs/040`（真机写 `/dev/fb0` 两帧可稳定上屏、1920×1080/虚拟 2160、需持有句柄）；`docs/043`（主线 6.3 已把 simplefb 保留跨度改 16 MiB 覆盖双缓冲）。 |
| 依赖 | ① 一个能注册 fb0 的内核：**社区/原厂 4.4 内核内建 hifb/VO/HDMI**（`docs/027 §4.1` 全部内建、无显示 `.ko`），或**主线 6.3 simplefb handoff 真机验证通过**（`docs/043` 这一版 CI 尚未刷入验证）；② `/dev/graphics/fb0`/`/dev/fb0` 节点权限；③ 双缓冲两帧都写、进程持有句柄（`docs/040`）。 |
| 风险 | ① 主线 6.3 目前显示/网络仍未打通（`docs/044`），**不能把「刷机 UI」押在未验证的 6.3 上**；过渡期需引入 4.4 内核私有显示栈，与「主线化」目标有张力；② 需把刷机执行者从 hiboot U 盘 `bootcmd`（bare metal）改成 Linux 用户态程序；③ 不是「通电零延迟」，需先起内核（秒级）。 |
| 是否动 p1 | **否**。 |
| 标注 | 实证基础 [观察]；「照搬到刷机阶段」[推断]（本机未做运行时验证）。 |

### 6.2 方案 B（次选，离散阶段可见）：中间系统二次写 p5 + reboot

**[观察]** `docs/039 §4.2` 给出**已验证先例**：社区包用 p7 busybox 中间系统 `dd` 覆写 p5 logo 并 `reboot`，实现「两次不同的开机画面」，**无需改 hiboot 二进制**。可推广为「每完成一阶段，把该阶段 logo（按 §4.1 的 `LOGO_TABLE` 格式：1920×1080 JPEG @0x2000 + `LOGO_KEY_LEN`=实际字节数）写进 p5 → `reboot` → hiboot 下次开机画出来」。

**[推断]** 依赖：① 一个能启动的 Linux 中间系统（社区有 p7 busybox，**我们目前没有**，`docs/039 §4.2` 明言）；② 每阶段一次重启；③ 状态必须存在 eMMC（哪张 logo 已写入），**不能**存在易失 env（`docs/036 §4.1`、`docs/037 §4.2 风险 9`）；④ reset 后 hiboot 究竟走「正常开机画 logo」还是「再导入 U 盘 bootcmd 走刷机分支」，需真机对齐（`docs/036 §4.1` 与 `docs/039 §3.3` 口径需核对）。

风险：画面是**离散阶段图**而非连续进度条；重启次数 = 阶段数；**不动 p1**。

### 6.3 不可行 / 否证的方案

| 方案 | 判定 | 依据 |
|---|---|---|
| C. 改 p1 hiboot（加显示命令/补丁显示初始化/直接往 VO 显存写进度） | **NO-GO** | §2 全文件负结果：无可达显示函数体、无显示命令、p1 内无 VO/HDMI MMIO 常量、无载荷；`docs/037` 五条门槛仍成立（无载荷、`go` ABI 不匹配、YZC/CRC 未逆向、无串口验证）；`docs/038` 仅部分推翻「写 p1 不可逆」的兜底否决项，**未**解决其余门槛。 |
| D. 利用 p7 `LOGO_TABLE` 多图切换做进度条/动画 | **否证** | §4：只有 1 张静态 JPEG、`LOGO_KEY_LEN` 即其字节数、无多帧序列、`logobak` 键不在 p7 内。 |
| E. 用 `usbboot` 等现有 U-Boot 命令触发显示 | **否证** | §2.2 命令表 44 条无显示命令；`usbboot` 是 legacy「USB 大容量存储分区启动」（`docs/038 §2.2`），与显示无关。 |
| F. pstore | **用户已否**，不纳入 | 任务约束。 |

### 6.4 明确答案

> **[推断] 最可行路径 = 方案 A**：**复用 p3 recovery 的「Linux 用户态 + fb0 进度 UI」机制**（进度条 PNG + 6 帧 spinner + 文字，`/sbin/recovery` 的 `/res/images/*.png` → `/dev/graphics/fb0` blit 思路），做成「刷机 UI 中间系统」。理由：它是唯一**不动 p1 二进制、不依赖 pstore、素材与代码路径都有静态/运行时实证**的方案；`docs/040` 已证明写 fb0 能持续上屏，`docs/023 §3` 已给出 fb0 几何/mmap 机制。**硬前提**是得有一个已打通显示栈的内核（短期用 4.4 私有栈、长期等 6.3 simplefb 真机验证），这是当前项目的真实瓶颈所在。
>
> 若只要求「阶段可见」不要求连续进度条，方案 B 是 `docs/039` 已验证的更轻先例，但需要一个能启动的中间 Linux 系统。
>
> **[观察] 不可把希望放在 p1**：原厂 1 MiB 虽比社区版多 97 条显示模块串，但两版都**静态定位不到可达显示函数体**；「通电立即显示」的 bootloader 侧机制在本轮方法范围内是 **[未知]**，不能靠改 p1 复用。

---

## 7. 证据边界、复现与合规

**边界**：全部为**只读静态分析**（外加 `docs/038` 已核实的公开文档级证据），**未观察到运行时执行**；静态不写成「运行时执行了…」。「0 命中」一律读作「在指定对象/扫描方式/范围内未检索到」。结论按 `docs/033 §2` 标 `[观察]`/`[推断]`/`[未知]`/`[存疑]`；函数体/调用点结论均有反汇编或结构化证据，注明对象 SHA-256、VA、工具版本；关键片段用 **radare2 6.2.4 + capstone 5.0.7 互验**（p1 指针搜索、cmd_tbl_s、main_loop 字面量池、p7 表头、recovery `0x26050` 取址）。

**[未知] 项**：p1 显示初始化函数体 VA 与调用点、`0x32000..0xBF688` 高熵数据的性质、fastapp/fastplay 模块是否在运行时加载显示实现、本机 `3.3.0-00786` 与板子页 `3.3.0-00709` 的显示分支一致性。
**[存疑] 项**：显示串簇是否纯属链接期导出符号表残留、reset 后 hiboot 的分支选择、方案 A 在 6.3 simplefb 上的可用性、7 张 `icon_installing_overlay*` 是否真为孤儿资源（本构建范围内未检索到按名引用）。

**复现产物（仓库内相对路径，均 gitignored）**：

| 文件 | 用途 |
|---|---|
| `TMP/stock-rom-research/display045/scan_p1.py` / `p1-scan.log` / `p1-scan.json` | p1 kallsyms/序言/bl 调用图/字面量/指针/ADR/movw-movt/命令表/MMIO 全扫 |
| `TMP/stock-rom-research/display045/logo.py` / `logo.log` / `logo.json` | p7 LOGO_TABLE 解析、图片签名结构化验证、gzip 解压校验、提取 |
| `TMP/stock-rom-research/display045/recovery_elf.py` / `recovery_elf.log` / `recovery_elf.json` | recovery ELF 节/符号/字符串 VA、ARM/Thumb 反汇编 xref |
| `TMP/stock-rom-research/logo-extract/logo_00_2000_1920x1080.jpg` / `logo_table_header_0x200.bin` | 唯一 JPEG 与 512 B 表头 |

**合规**：只读；不刷机、不改真机、不构建镜像、**不删除文件**、不用 `rm` / `git clean`、不访问项目目录之外的本地目录、不写入仓库外文件；临时产物全在 `TMP/stock-rom-research/` 下；文档不含本机绝对路径 / 用户名 / 卷名 / IP / 凭据，厂商构建机标识省略；**只新建 `docs/045-stock-boot-display-mechanism.md` 一个文件**，未改动任何已跟踪文件，未执行 `git add` / commit / push / checkout / 建分支 / 动索引，由主会话统一提交。
