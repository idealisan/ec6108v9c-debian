# 045 — 引导程序如何绘制图像（链路坐实）与刷机阶段进度显示

> 2026-11-08，**按用户最高优先质疑重排**。用户连问两句：「其实到现在都没有搞清楚，刷机程序和引导程序究竟是如何绘制图像的，这是最基本的要求」「一定要用阶段图吗？不能像普通程序那样填充颜色吗？做图片引用图片资源更复杂」。
>
> 本文据此把**唯一核心任务**收敛为：**坐实「引导程序把 p7 那张 JPEG 变成屏幕像素」的完整链路**，正面回答 (a)-(d)。进度方案、颜色编码、`mw.l`、fastPlay、p3 recovery UI 全部降为附录。
>
> **诚实前提（接受，不再堆方案）**：此前 `docs/046` 一类「阶段图 / `mw.l` 填色」方案都建立在「知道显存往哪写、VO 在刷机分支是否已初始化」这个未查清的前提上，是本末倒置。本文先解决基本原理，最后只给一句「最简单的呈现方式 + 还差哪个最基本事实」。
>
> 方法：`docs/033 §2` REA 三分法；**先分离代码区/数据区（字符串密度 + 函数序言密度），再谈反汇编**；capstone 5.0.7（ARM A32 与 Thumb-2 均扫、`skipdata=True`）与 radare2 6.2.4 互验；不靠 strings/文件名/魔数推断行为；注明对象 SHA-256 / VA / 工具版本。
>
> 相关：`docs/023`（recovery 显示 / SDK 源码）、`docs/027`（整机备份 §4.7/§4.8）、`docs/031`/`037`（社区 hiboot 负结果）、`docs/035`（recovery 内核 kallsyms 重建）、`docs/036 §4.2`（刷机分支不初始化显示）、`docs/038`（histb 板子页 boot log）、`docs/039`（社区两张 logo）、`docs/040`（真机写 `/dev/fb0`）、`docs/043`（6.3 simplefb/VO 地址实测）。

---

## 0. 结论先行 —— 直接回答 (a)-(d)

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| (a) | **p1 代码区在哪、多大？`0x79000` 之后是不是数据/符号池？ARM/Thumb 实际分布？** | 代码区 = `0x2000..0x79000`（ARM A32，**1,359 个函数序言**，4 字节字 **85.4% 为 `0xE` AL 条件码**）+ `0x94000..0x97000` 独立 DDR 训练 blob（29 个序言）；**`0x7A000..0x93000` 是数据/字符串/符号名池（0 序言、可打印比最高 0.91）**；`0x97000..0x100000` 全 0。**无真实 Thumb-2 代码区**：Thumb 模式扫出的 550 个「序言」与 ARM 代码区同比分布，是把 ARM A32 机器码误解码的假阳性（两个疑似 Thumb 块 `0x6A000` / `0x7E000` 的 AL 条件码分别 0.924 / 0.023）。 | [观察] |
| (b) | **显示函数机器码是否链接进 p1？** | **否（就本文分析的这份 p1 镜像）**。`PRODUCT_DisplayInit`/`Logo_Main`/`HDMI_Display`/`HI_GFX_ShowLogo`/`PDM_ReadLogoData`/`HI_LOGO_DecImg`/`HI_DRV_PDM_AllocReserveMem` 在 p1 里只是 **`0x79000` 之后的 ASCII 符号名/日志串**（与 `fastapp_entry`/`HI_UNF_OTP_*`/`DISP_*` 同一 20 字节定长表），**0 代码引用**；p1 内 **无 `0xf8cc0000`/`0xf8ce0000` VO/HDMI MMIO 常量**（字面量、movw/movt 构造均 0 命中）。→ 显示实现**不在 p1**，这些串是 stripped 符号名池 / 模块清单残留。最可能载体见 §1.6。 | [观察] + [推断] + [未知] |
| (c) | **p7 JPEG 被谁读、解码到哪块内存？显存物理地址来源？VO G0_ADDR 写什么值？** | [观察] p7 容器是单张 1920×1080 JPEG @`0x2000`（190,496 B）；p1 有 `logo`/`logobak`/`LOGO_KEY_FLAG`/`LOGO_KEY_LEN` PDM 键与「`ERR: Can not find logo flash data!` / `ERR: HI_Flash_Read` / `playparam`」簇，但**同样 0 引用**。[观察] 原厂 4.4 内核 kallsyms 有 `hifb_logo_init`@`0xc0333378`、`hifb_set_logosd`@`0xc0333418`、`HifbSetLogoLayerEnable`@`0xc0339814`、`fb_show_logo`@`0xc01d4884` 与 `HI_DRV_PDM_*` 驱动，但**没有** `PDM_ReadLogoData`/`HI_LOGO_DecImg`/`PRODUCT_DisplayInit` 这些函数符号。[推断] 显存由 `HI_DRV_PDM_AllocReserveMem` 从 MMZ（`mmz=ddr,0,0,400M` 正常 / `256M` recovery，随 `mem=` 变）**运行时分配**，VO `G0_ADDR/G0_STRIDE/G0_IRESO` 由 `docs/023 §4.3`（SDK 源码）的 `PRODUCT_DisplayInit → HI_GFX_ShowLogo` 配置。[观察] 运行时实测值：社区系统 VO layer0 `fb_phys≈0x3f6ce000`（`docs/043` pstore 期望）、hifb `smem_start=0x3C55C000`（`docs/040`，1920×1080 ARGB8888 / stride 7680）。**[未知]** G0_ADDR 的确切写入值、**同一硬件跨次上电是否稳定**、JPEG 解码器在哪个二进制 —— **不编造地址**。 | [观察] + [推断] + [未知] |
| (d) | **「正常开机画 logo」与「短接刷机不画」是不是两条不同执行者/二进制？** | **不是不同执行者**（[推断]）：4 份 fastboot 是**同一 U-Boot 代码库的 4 个构建**——reset 向量全为 `0xea000819`、`YZCv1.1.0@0x3d`、`mw` 全在；社区 U 盘根 `fd5b4ac6…` 与内层写 p1 的 `3bded87f…` 字符串集 **2,656 共享 / 仅 6 各异**（同一构建，只差版本串），原厂 p1 `bac0be9f…` 与社区 **1,781 共享 / 710 / 881**（不同构建）。按 `docs/036 §1.3`/`§4.2`、**同一份 hiboot 走不同分支**：正常开机路径画 p5/p7 logo，U 盘 `bootcmd` 刷机分支**不做显示初始化、不刷新 HDMI**（用户「刷机时背光都不亮」与此一致）。 | [观察] + [推断] |
| — | **显示代码到底在不在 p1？** | **明确判定：不在（本文这份 `bac0be9f…` 镜像）**。字符串在、实现不在；这不是扫描盲区（§1.2 已逐一排除 ARM/Thumb/绝对指针/PIC 相对/第二基址/压缩段/ELF 符号表六种可能），而是「p1 里只有一份 dead 符号名池」。 | [观察] + [推断] |

---

## 1. 【核心】引导程序如何绘制图像：链路图 + 每环证据等级

### 1.1 (a) 先把代码区与数据区分开（REA：别把数据当代码）

**[观察]** 对 `p01_fastboot.img`（1,048,576 B，SHA-256 `bac0be9ff5926de1c813668216977c85e1903ceb3e69b83e5a7ffb2156b0c073`）按 4 KiB 块统计：ARM 函数序言数（`push/stmdb` 含 `lr`、`mov ip,sp`）、Thumb-2 序言数、可打印字节比、全 0 比。capstone 5.0.7 `skipdata=True` 全文件覆盖（ARM 262,144 条指令；Thumb 511,837 条）。

| 区间 | 块数 | 分类 | ARM 序言 | 可打印比 | 判据 |
|---|---|---|---|---|---|
| `0x0..0x2000` | 2 | 头/DDR 寄存器表 | 0 | 0.07 | `###` 式寄存器对、`YZCv1.1.0@0x3d`、`Reg Name:` 等 |
| `0x2000..0x79000` | ~110 | **ARM A32 代码** | **1,321** | 0.16–0.20 | 4 字节字 **85.4% 为 `0xE` AL 条件码**；序言密度均匀（16 KiB 桶 24–81 个） |
| `0x7A000..0x7E000` | 5 | 数据/符号名池 | 0 | 0.17–0.42 | 20 字节定长函数名表（`HI_UNF_HDMI_*`/`DISP_*`/`PDM_*`/`HI_UNF_OTP_*`/`fastapp_entry`） |
| `0x7F000..0x8F000` | 16 | **字符串/数据** | 0 | **0.91** | `boot logo show!!!`、`=====FILE: %s, LINE: %d, Ret:%x`、`higo/adp_gfx.c`、`LOGO_TABLE`、U-Boot 通用串 |
| `0x8F000..0x94000` | 5 | 数据（命令表等） | 0 | 0.13 | `cmd_tbl_s` @`0x93A2C` 起 44 条 |
| `0x94000..0x97000` | 3 | **独立 ARM 代码 blob** | 29 | 0.30 | `ddr_*` 函数名 / `PHY[%x]` / DDR 训练日志（BootROM 加载的 DDR 训练段） |
| `0x97000..0x100000` | 105 | 全 0 填充 | 0 | 0.00 | 430,135 B 零 |

**[观察] ARM/Thumb 判定**：Thumb 模式全文件扫出 550 个「`push {..,lr}`」，但它们与 ARM 代码区**空间重合且成比例**（如 `0x2000..0x1C000` ARM 360 / Thumb 146），字符串区与零区均 0；两个被自动标成「THUMB-CODE?」的块实测 `0x6A000..0x6B000` AL 条件码 0.924（纯 ARM）、`0x7E000..0x7F000` 0.023（已是字符串前导数据）。→ **p1 无真实 Thumb-2 代码区，全部为 ARM A32**；用 Thumb 解码 ARM 机器码得到的指令是假象（与 team-lead 本轮发现的 `0xC79EF0` 假阳性同源）。`docs/033 §2` 留痕剔除。

**[观察] 链接基址**：`0x00C00000` 以 **1,706 个字符串指针**投票确认（次优仅 142）；以「每个候选基址对应多少个**不同**指针字」复核**第二链接基址**：最高 `0x00C10734` 仅 66 个不同字，且集中在 `0x00C10xxx` 一片噪声 → **无第二基址**，排除「显示模块是另一个链接基址的独立段」。radare2 `pxw @ 0x00c23468` 复核 main_loop 字面量池（`0x00c8b957`=`bootcmd`、`0x00c8b993`=`Press Ctrl+C`）与 capstone 一致。

### 1.2 (b) 显示函数机器码是否链接进 p1 —— 六种盲区逐一排除

**[观察]** 以 `PRODUCT_DisplayInit`@`0x7937C`、`Logo_Main`@`0x79390`、`HDMI_Display`@`0x79D18`、`PDM_ReadLogoData`@`0x7A004`、`HI_LOGO_DecImg`@`0x7A130`、`HI_DRV_PDM_AllocReserveMem`@`0x79F4C`、`boot logo show!!!`@`0x7F65C`、`LOGO_TABLE`@`0x81BD0`、`=====FILE: %s, LINE: %d, Ret:%x`@`0x80440`、`higo/adp_gfx.c`@`0x835BC` 为锚点，穷举：

| 盲区假设 | 检查方式 | 结果 |
|---|---|---|
| 绝对指针字 | 任意对齐 4 字节搜索 `BASE+off`（含 ±0x20 窗口） | **0 命中**（唯一 `0x28A18` 落在 `PRODUCT_DisplayInit` 附近，实为 zModem 错误串表 `0x00c7935c` 的假阳性） |
| ARM `ldr [pc,#imm]` 字面量 | 4,668 个字面量池全扫 | **0 命中**（对照：U-Boot 通用串在 0x84000–0x8C000 桶有 1,379 个引用，显示串所在 0x79000–0x83000 几乎不被引用） |
| PIC 相对引用（`ldr rX,[pc,#imm]` 装**偏移** + `add rX,pc`，即 `/sbin/recovery` 的那种） | ARM A32 全扫 6,025 个 `ldr[pc]` / 578 个 `add/sub…pc` / **718 组 `ldr..add(pc)`** | **0 组** `pc+off` 落在显示串区（§1.2 新增，闭合了此前的真正盲区） |
| Thumb-2 相对引用 | Thumb 全扫 2,114 个 `ldr[pc]` | 3 处 `pc+off` 落进显示串区，但地址 `0xC79FDC`/`0xC7A114`/`0xC7A8AE` 处字节分别是 `'HI_DRV_PDM_GetPmocParam'`/`'HI_UNF_OTP_Get_CustomerKey'`/`'DISP_HAL_GetVersion'` 等 **ASCII 文本** → 数据误解码成指令，**假阳性，剔除** |
| `adr` / movw-movt 常量构造 | `adr` 助记符 0 条；movw/movt 对构成显示串 VA 0 组；构成 `0xf8cc0000`/`0xf8ce0000` 0 组 | **0 命中** |
| 第二链接基址 / 压缩段 / ELF 符号表 | 见 §1.1；p1 无 gzip/xz/zlib 魔数、最高 4 KiB 熵 6.84、无 `Compressed-boot` 串；`kallsyms*`/`__ksymtab_`/`\x7fELF` 全 0 命中 | **排除** |

**[观察]** 不仅如此，**整片** flash-read / 显示日志串簇也是 dead rodata：`ERR: Can not find logo flash data!`@`0x81388`、`ERR: HI_Flash_Read, ReadLen`@`0x813AC`、`fastplay`/`fastplaybak`/`playparam`@`0x813D0`、`ERR: PDM_ReadPlayParam`@`0x81448` 全部 **0 引用**；`there is no logo param!`@`0x81B98`、`LOGO_KEY_LEN`@`0x81BEC` 同样 0 引用。

**[观察] 交叉验证（4 份构建的符号名池是共享的 dead 数据）**：`PRODUCT_DisplayInit`(2)、`Logo_Main`(1)、`HDMI_Display`(3)、`PDM_ReadLogoData`(1)、`HI_DRV_PDM_AllocReserveMem`(1–2)、`boot logo show!!!`(1) 在**原厂 p1 / 社区顶层 / 社区内层 / burn 四份里都作为字符串存在**；`=====FILE:` 格式串与 `higo/adp_gfx.c` **仅原厂 p1 有**（多 97 条 higo/GFX/DISP/VDP 串）。`docs/031`/`037` 已证社区 539 KB 版这些串 0 引用；本轮证原厂 1 MiB 版同样 0 引用。→ **[推断]** 这是 SDK 构建系统生成的**导出符号名/模块清单池**，被链接进所有 fastboot 构建但**不参与运行时**，不是「显示函数体可达」的证据。

> **[观察] 结论 (b)**：显示实现**未链接进本文分析的 p1 镜像**；给不出函数体 VA / 调用点 / 寄存器写入序列，标 `[未知]`，**不编造地址**。p1 内也**没有** `0xf8cc0000`（VO/VDP）/`0xf8ce0000`（HDMI TX）等 MMIO 常量——一份会配置 VO 图层的代码按理应出现这类基址（`docs/023 §4.2/4.4` 的 SDK 头即如此），这从第二个角度印证「p1 内无显示初始化代码」。[未知] 不排除基址由运行时变量/寄存器表间接给出，但本镜像内**找不到结构性证据**。

### 1.3 (c) 谁读 p7 JPEG、解码到哪、显存地址从哪来

**[观察] 载体与容器**：`p07_logo.img`（4 MiB，SHA `cfc5db33166cbdf72577690b2d661647524c5138cf012ebdca52b2ed9f178ae6`）：`###\0` + 表长 `0x7C` + `LOGO_TABLE` + `LOGO_KEY_FLAG=1` + `LOGO_KEY_LEN=0x2E820`(190,496) + **单张 1920×1080 JPEG @`0x2000..0x30820`**（`sips` 复核 1920×1080，SOI/EOI 齐全）。用户已亲眼确认这张图就是原厂开机「早期阶段」画面（team-lead 转述，[观察] 级）。p15 内 `etc__recovery__defaultlogo__logo.img`(81,920 B) 与社区 `mv100/logo.img`(65,536 B) 是**同一单图容器格式**（`LOGO_KEY_LEN` 分别 `0x101C5` / 54,221）。

**[观察] 读取方（尽可能坐实）**：
- p1 有 PDM 键 `logo`/`logobak`/`LOGO_KEY_FLAG`/`LOGO_KEY_LEN` 与「`ERR: Can not find logo flash data!` / `ERR: HI_Flash_Read`」日志串 → **[推断]** 存在一个「按 PDM 键名从 flash 读 logo 数据」的例程；但**该例程机器码不在 p1**（§1.2，0 引用）。
- 原厂 4.4 内核（`p11_vmlinux.bin` 17,432,904 B / `recovery-vmlinux.bin` 8,227,512 B）：`docs/035` 重建的 35,937 个 kallsyms 符号里**有** `HI_DRV_PDM_Init`@`0xc02bfe4c`、`DRV_PDM_GetDispParam`@`0xc02c1150`、`HI_DRV_PDM_ReleaseReserveMem`@`0xc02c07e4`、`PDM_VmapByPhyaddr`@`0xc02c0800`、`hifb_logo_init`@`0xc0333378`、`hifb_set_logosd`@`0xc0333418`、`HifbSetLogoLayerEnable`@`0xc0339814`、`VDP_GFX_SetLayerAddr`@`0xc02fd210`、`fb_show_logo`@`0xc01d4884`、`register_framebuffer`@`0xc01d56c0` —— 即**内核有 PDM 驱动、VO/GFX 图层地址配置、hifb logo 图层机制**；但**没有** `PDM_ReadLogoData`/`HI_LOGO_DecImg`/`PRODUCT_DisplayInit`/`Logo_Main` 这些函数符号（它们在 vmlinux 里只是 rodata 字符串）。
- 社区真机运行态（`docs/040`）：`/proc/fb` = `0 hifb`、`/dev/fb0` 双缓冲 1920×1080 / 虚拟 2160 / stride 7680、`smem_start=0x3C55C000`；`docs/043` 主线驱动从 **VO 寄存器**运行时发现显存，实测 `fb_phys≈0x3f6ce000`。二者是**运行时测量值**，不在任何静态二进制里作为常量出现。

**[推断] 显存物理地址来源**：`HI_DRV_PDM_AllocReserveMem` 从 **MMZ 运行时分配**（`mmz=ddr,0,0,400M` 正常启动 / `256M` recovery cmdline，随 `mem=1G/2G/512M` 变），解码后的 logo 帧缓冲地址写入 VO `G0_ADDR/G0_STRIDE/G0_IRESO`（`docs/023 §4.3` SDK 源码：`PRODUCT_DisplayInit → HI_GFX_ShowLogo` 配置 VO 图层），Linux 起来后 hifb 通过 `hifb_logo_init` / `HifbSetLogoLayerEnable` 接管/释放这块 logo 内存。时序来自 sink EDID（`SinkCap.stPerferTiming`），不是硬编码常量。

**[观察] 对 team-lead「`PDM_ReadLogoData`/`HI_DRV_PDM_AllocReserveMem` 返回地址是否写入固定 VO 寄存器或全局」的直接回答**：在 p1、p05、p11_vmlinux 内**均未检索到**把该返回地址写入某个固定全局/VO 寄存器的代码——因为该例程机器码本身不在 p1（§1.2），p11/p05 内也无 `0xf8cc0000`/`0xf8ce0000` 类 VO 常量与之配对；唯一相关的是内核 kallsyms 里 `PDM_VmapByPhyaddr`@`0xc02c0800` / `VDP_GFX_SetLayerAddr`@`0xc02fd210` 这类**函数符号**，其写入值只能在运行时读寄存器得到（`docs/043` 的 `fb_phys` 即如此）。

**[未知]（明确不编造）**：① JPEG 解码器 `HI_LOGO_DecImg` 的实现在哪个二进制；② VO `G0_ADDR` 被写入的**确切物理地址**；③ 该地址在同一硬件/同一 hiboot 构建下**跨次上电是否稳定**（`docs/043` 只有一次社区系统测量，`docs/040` 的 `0x3C55C000` 是社区内核 hifb 的 `smem_start`，两者且**互不相同**、都未证明等于原厂 p1 的 logo 帧缓冲）。静态 `bootcmd` 文本要写死 `mw.l <addr>` 就必须先回答 ③，本轮**不能给地址**。

### 1.4 (d) 正常开机画 logo vs 短接刷机不画：执行者与二进制判定

**[观察] 4 份 fastboot 结构对照**：

| 对象 | 大小 | SHA-256 | reset 向量 | YZC | 命令数 | 字符串数 | `mw` |
|---|---|---|---|---|---|---|---|
| 原厂 p1 `p01_fastboot.img` | 1,048,576 | `bac0be9f…` | `0xea000819` | `@0x3d` | 44 | 2,491 | 有 |
| 社区 U 盘根 `fastboot.bin` | 539,264 | `fd5b4ac6…` | `0xea000819` | `@0x3d` | 51 | 2,662 | 有 |
| 社区内层 `mv100/fastboot.bin`（写 p1） | 539,272 | `3bded87f…` | `0xea000819` | `@0x3d` | 51 | 2,662 | 有 |
| 本机构建 `fastboot-burn.bin` | 519,468 | `d5bb8272…` | `0xea000819` | `@0x3d` | 40 | 2,511 | 有 |

- 社区根 vs 内层：**2,656 串共享 / 各仅 6 串不同**（版本串/构建日期 + 8 字节长度差）→ **同一构建**，只换版本串（`docs/038 §3` 逐指令结构比对亦证 `usbboot` 112/112、DOWN-check 8/8 相同）。
- 原厂 p1 vs 社区：**1,781 共享 / 710 / 881** → **不同构建**（原厂多 higo/GFX/DISP/VDP 符号串与 DDR 训练 blob；社区多自己的命令/日志）。
- **4 份都带同一份显示符号名池**（§1.2），说明它不是「某份镜像独有功能」。

**[观察]→[推断] 判定**：三个 SHA-256 是**同一 U-Boot 代码库的三个构建**，**不是三个不同阶段的执行者**。「正常开机画 logo」与「短接刷机不画」按 `docs/036 §1.3`/`§4.2` 是**同一份 hiboot 的两条分支**：正常开机路径读 p5/p7 logo 并画；U 盘 `bootcmd` 刷机分支（`run flashfastboot; …; reset`）**不做显示初始化、过程中不刷新 HDMI**。用户「刷机时背光都不亮」与此一致。[存疑] 本轮 (b) 又发现 p1 内根本没有显示实现代码，故「正常开机画 logo」的实际执行模块可能不是我们备份的这份 p1（§1.6），但「刷机分支不初始化显示」这一结论由 `docs/031 §3`/`docs/036 §4.2` 的实证 + 用户观察**独立成立**。

### 1.5 链路图（每环证据等级）

```
[观察·文档] BootROM → DDR 训练 → 加载 p1 fastboot（reset 向量 0xea000819）
                 │
[观察] p1 代码区 0x2000..0x79000（ARM A32）；main_loop 字面量池 @0x23468 指向 bootcmd/Press Ctrl+C
                 │
        ┌────────┴─────────────────────────────┐
   正常开机分支                              短接 U 盘刷机分支
        │                                          │
[观察] p02 env bootcmd=mmc read …; bootm …    [观察] U 盘 bootargs.bin → bootcmd 一串 fatload+mmc write+reset
        │                                          │
[推断] 显示初始化（HDMI PHY/EDID/VO 图层）    [观察·docs/036 §4.2] 不做显示初始化、不刷新 HDMI
        │  ← 实现代码不在本文 p1（§1.2）            │  ← 用户「背光都不亮」
[推断] 从 p7 读 LOGO_TABLE → JPEG 解码           [未知] 写显存也不会被扫描 → 无色可见
        │  ← 读取/解码例程不在 p1、不在内核符号表（§1.3）
[推断] 解码结果写入 MMZ 运行时分配的帧缓冲，VO G0_ADDR 指向它（地址 [未知]）
        │
[观察·用户] p7 那张 1920×1080 JPEG 出现在开机早期屏幕
        │
[观察] Linux 4.4 内核 hifb_logo_init / hifb_set_logosd 接管 logo 图层；
       docs/040 真机 /dev/fb0 写满双缓冲两帧可持续显示
```

**每环证据等级**：BootROM→p1 [观察·文档]；p1 代码区/分支 [观察]；显示初始化 [推断]（实现位置 [未知]）；p7 读取/解码 [推断]（例程位置 [未知]）；帧缓冲地址 [未知]（仅运行时测量值，且两处不一致）；p7 图出现 [观察·用户]；Linux 接管 [观察]。

### 1.6 硬矛盾消解（team-lead 要求「不能两边都挂着」）

> **矛盾**：用户亲眼看到原厂开机显示 p7 那张 JPEG（[观察]，最硬）；但 `docs/031/037` 与本文都发现显示函数名在 p1 里是孤立字符串、0 代码引用。
>
> **[观察] 消解**：这两件事**不在同一对象上**。「显示发生」是运行时事实；「0 代码引用」是对**本文备份的这份 `bac0be9f…` p1 镜像**的静态结论。本文已把「扫描有盲区」的六种可能逐一排除（ARM 绝对指针、ARM 字面量、**PIC 相对引用这一真正盲区**、Thumb-2、第二链接基址、压缩段/ELF 符号表；§1.1–1.2），结论稳定：**这份 p1 里只有一份所有 fastboot 构建共享的 dead 符号名池，没有显示实现代码**。因此不是「扫漏了」，而是「画 logo 的代码不在这份二进制里」。
>
> **[推断] 最可能载体（按可能性排序，均 [未知] 待证）**：
> 1. **另一个 fastboot 构建**：`docs/038` 核实的 histb 板子页 boot log（构建 `3.3.0-00709`）**运行时打印** `=====FILE: higo/adp_gfx.c, LINE: 150, Ret:b0038002` —— 那份构建里 higo/GFX 模块是**真链接并运行**的；而我们备份的是 `3.3.0-00786`，只剩格式串与源码路径名。→ 同一 SDK、不同裁剪，显示模块在别的构建里。
> 2. **运行时加载的独立模块（fastapp/fastplay）**：p1 有 `fastapp_entry`、`fastplay`/`fastplaybak`/`playparam` PDM 键与 `initrd=0x2500000,0x1300000 mmz=ddr,0,0,256M root=/dev/ram` 的 ramdisk cmdline；但本备份 `p08_fastplay` 分区**全 0**，无载荷可分析。
> 3. **内核侧 hifb logo 图层交接**：4.4 内核确有 `hifb_logo_init`/`hifb_set_logosd`（kallsyms 实证），但**没有 JPEG 读取/解码函数**，只能「接管」不能「从零画出」。
>
> **[未知] 保留**：究竟哪份二进制把 JPEG 解码并写进 G0 图层，本轮**未坐实**；不编造地址、不把 SDK 源码推测写成固件实证（`docs/033 §2` 第 4 条）。

---

## 2. 【附录 A】颜色编码进度方案（`mw.l`）—— 判定与肯定可行替代

> 用户诉求：「输出文字日志麻烦的话，至少让屏幕显示某个颜色代表某个阶段；总之得有个渠道知道进度」。按最新指令，此节为附录，但给出明确 能/否/存疑 判定。

### A.1 `mw` 能力（[观察]，team-lead 硬证据 + 本轮结构化复核）

**[观察]** 4 份 fastboot 均有 `cmd_tbl_s` 的 `mw` 记录；原厂 p1 记录 @`0x93C24`：`name='mw' maxargs=4 repeatable=1 cmd=0x00C1AB9C`，`usage='memory write (fill)'`，**`help='[.b, .w, .l] address value [count]'`**。radare2/capstone 对命令表结构互验一致。→ `mw.l <addr> <ARGB8888> <count>` 的 32-bit 填充语法**成立**；我们自己的 `loadfileb` 已在用 `mw.b 0x1000000 0xFF 0x10000`。**`mw` 命令本身不是障碍。**

### A.2 决定性前提：刷机分支执行时 VO/HDMI 是否已初始化并持续扫描显存

**[观察] 否（这是方案不成立的第二个、也是最硬的原因）**：
- `docs/031 §3` / `docs/036 §4.2` 实证：**「U 盘刷机分支不做显示初始化、过程中不刷新 HDMI；只有另一次正常开机才画 p5 logo」**。
- 用户多次观察「刷机时显示器背光都不亮」→ 无 HDMI 信号 → VO/HDMI PHY 在刷机分支未开启。
- 本文 §1.2/§1.4 补强：p1 内**没有显示初始化实现代码**，刷机分支更无从触发它。
→ **[推断]** 刷机执行期间即使 `mw.l` 往某块内存写满 ARGB 颜色，**VO 没有在扫描它 / HDMI 没有输出**，屏幕不会变色。`docs/040` 的「写 `/dev/fb0` 立即上屏」是**Linux 起来、hifb 驱动已注册 fb0 之后**的运行态，不能直接搬到「只有 p1 hiboot 的刷机阶段」。

### A.3 显存物理地址能否给静态 `bootcmd` 用

**[推断] 不能（地址运行时动态分配）**：`HI_DRV_PDM_AllocReserveMem` 从 MMZ 分配（`mmz=ddr,0,0,400M` 正常 / `256M` recovery，随 `mem=` 变化）；`docs/040` 的 `smem_start=0x3C55C000`（社区内核 hifb）与 `docs/043` 的 `fb_phys≈0x3f6ce000`（VO layer0 运行时读寄存器）**是两个不同、且都只在运行时测到的值**，都不等于「原厂 p1 画 logo 的帧缓冲」，也**未证明跨次上电稳定**。`bootcmd` 是静态文本，无法运行时读 `VO_G0_ADDR`。
**[未知]** 若某天在**同一硬件/同一构建**上重复实测证明该地址固定，才可能把常量写进 env；本轮无此证据，**不给地址**。

### A.4 判定（team-lead 要求的「能/否/存疑」）

> **[推断] 「颜色编码阶段只靠改 bootargs.bin（插 `mw.l`）」＝ 否**。两个独立阻断点：① 刷机分支 VO/HDMI 未初始化、不扫描显存（A.2，[观察]）；② 显存地址运行时分配、静态文本不可知（A.3，[推断]+[未知]）。`mw` 命令支持 `.l` 不足以救活这条路径。**不用 pstore**（用户已否）。

### A.5 肯定可行的落地路径（用户底线：必须有个渠道知道进度）

**[推断] 唯一已实证、只改 `bootargs.bin` 的可判读渠道 = `docs/036 §4.2` 零风险方案**：
- 把「链尾一张固定 Debian logo」改成**每步执行前先把该步的 stage logo 写进 p5**；stage logo 用**纯色 1920×1080 JPEG 装进单图 `LOGO_TABLE` 容器**（红=开始 / 黄=写 kernel / 蓝=写 rootfs / 绿=完成），即「颜色编码」，但**以图片为载体会被 hiboot 在下次正常开机画出**。
- 用 `;` + `if`（不用 `&&`），不增加 `reset`、**不碰 p1**、不改显示初始化。
- 刷机执行期间屏幕仍不亮；但一旦中途卡死/断电，**用户重启后正常开机画出的 p5 就是「卡在第 N 步」的那张颜色** → 首次提供可判读的进度/失败位置。
- 实证基础：`docs/039` 社区包「两次写 p5 + 两次开机各画一张」**真机验证过**；`docs/036 §4.2` 已把它列为零风险最小改造。
- 风险/依赖：不是「实时」显示；需制作 N 张合法单图 LOGO_TABLE（格式见附录 B）；需用 `if`+`mmc read`/`cmp` 跳过已完成阶段以免 `reset` 后从头循环（`docs/036 §4.1` env 每轮重导入）。
- **[推断] 与并行 `docs/046` 的关系**：`docs/046` 的「分阶段独立 U 盘包 + 阶段图写 logo 分区 + `reset`」是同一机制的更完整工程化版本（同样只改 `bootargs.bin`、不动 p1），可作首选落地；但其「上电第一张阶段图立刻出现」仍依赖「hiboot 开机必画 p5」这一环，而本文 §1.2 已证**该绘制实现不在我们备份的 p1 内**——故两文结论不冲突，只是 `docs/046` 的判据需按 §1.6 补上「实现载体 [未知]」这一条。

**[推断] 若要「刷机过程中实时变色」**：只能走两条更重的路 —— (i) **改 p1 二进制**让刷机分支也初始化 HDMI（`docs/036 §4.2` 路径 A），但本文 §1.2 已证**显示实现代码不在 p1、无载荷可打**，`docs/037` NO-GO 判定不变；(ii) **引入一个已打通显示栈的 Linux 中间系统**（4.4 内核 hifb 或等 6.3 simplefb 真机验证通过），由用户态写 `/dev/fb0` 画色块（`docs/040` 实证、`docs/023 §3` fb0 机制、附录 C 的 p3 进度 UI 素材），代价是换刷机执行者、且不是「通电零延迟」。两者都**不是只改 bootargs.bin**。

---

## 3. 【附录 B】p7 LOGO_TABLE 结构（单张图，多图切换否证）

**[观察]** `###\0` + `table_len=0x7C` + `LOGO_TABLE`(32 B 键名) + `0x50` + `LOGO_KEY_FLAG`(32 B) + 值长 4 + **FLAG=1**@`0x50` + `LOGO_KEY_LEN`(32 B) + 值长 4 + **LEN=0x2E820(190,496)**@`0x78` + 表结束；结构为「32 B 键名 + 4 B 值长度 + 值」定长表。`LOGO_KEY_LEN` **恰等于** `@0x2000` 那张 JPEG 的字节数，`LOGO_KEY_FLAG=1` = 图有效/存在。radare2 `pxw @ 0x0/0x74` 与 Python 互验。

**[观察] 只有一张图、无动画/进度序列**：唯一有效 JPEG @`0x2000..0x30820`（1920×1080，`sips` 复核，已提取 `TMP/stock-rom-research/logo-extract/logo_00_2000_1920x1080.jpg`）；PNG 0、有效 BMP 0（11 处 `BM` 的 DIB/宽高全是乱码）、有效 gzip 0（40 个 `1f 8b` 候选 `zlib.decompressobj` 全失败）；`0x32000..0xBF688`（579,208 B ≈ 566 KiB）为高熵≈7.0 无结构数据，`###`/`LOGO_TABLE`/JPEG/PNG 签名 0，性质 **[未知]**，不据此推断第二张图。`logobak` 键在 p7 内**范围内未检索到**（只在 p1 rodata 作 PDM 键串）。p15 `defaultlogo/logo.img`(81,920 B) 与社区 `mv100/logo.img`(65,536 B) 同为**单图**容器。

→ **[观察] 判定**：`p07_logo.img` 是**单张静态开机 splash**；「往一个容器里塞多张、让 hiboot 按阶段选」**不成立**——表内只有 3 个键、`LOGO_KEY_LEN` 只描述一张，且 PDM 解析例程不在 p1（§1.2）无法反汇编确认「是否只认第一张」，标 **[未知]**，按最坏情况判否。真正可行的「多图」是 `docs/039` 那种**同一容器、多次覆写 p5 + 多次开机**（附录 A.5），不是容器内多图索引。

---

## 4. 【附录 C】p3 recovery 进度 UI（现成素材，非 bootloader 阶段）

**[观察]** `p03__res__images__*.png` 全部合法 PNG：`progress_empty/fill`(474×14，进度条)、`indeterminate01-06`(252×7，6 帧不确定进度)、`icon_installing_overlay01-07`(110×132，7 帧安装动画)、`icon_installing`(580×120)、`installing_text`(480×1898) 等，是一套完整 Android recovery 安装 UI。

**[观察] 反汇编级证据（radare2 + capstone 互验）**：`p03__sbin__recovery` 为 ELF32 ARM（`e_entry=0x80F8`，`.text` 0x542E4、`.rodata` 0x105F0，符号表 0 条，ARM/Thumb-2 混编 PIC）。radare2 `axt @ 0x637E4`（`/res/images/%s.png`）给出 `fcn.00026050 @0x2606c add r2, pc`；capstone Thumb-2 复核：

```
0x00026068  ldr r2, [pc, #0x204]   ; pool@0x26270 = 0x0003d774
0x0002606C  add r2, pc             ; 0x26070 + 0x3d774 = 0x637E4 = "/res/images/%s.png"
0x00026088  bl   #0x46680          ; 资源名格式化 / surface 加载
```

`.rodata` 另有 `/dev/graphics/fb0`、`failed to mmap framebuffer`、`framebuffer: fd %d (%d x %d)`、`KDSETMODE to KD_GRAPHICS`、`indeterminate%02d`；`init.rc` 有 `service recovery /sbin/recovery`、`ueventd.rc` 有 `/dev/graphics/* 0660 root graphics`。→ **[推断]** 按 `/res/images/%s.png` 拼名加载 PNG，`open("/dev/graphics/fb0")` + `FBIOGET_*` + `mmap` blit（`docs/023 §3` 同结论），**依赖内核已注册 fb0**。7 张 `icon_installing_overlay*` 在本二进制里**范围内未检索到按名引用**（默认 AOSP 残留），真正在用的是 6 帧 `indeterminate%02d`。

---

## 5. 【附录 D】通电立即显示的时间线（[推断] 为主）

```
[观察·文档] Bootrom start → Boot from eMMC → Initializing DDR / DDR training → Starting fastboot
[观察·二进制] p1 首阶段串 System startup / Reg Version: v1.1.0 / Reg Name: <.reg> / Relocate Boot to DDR / Jump to DDR
              （@0x24BC / 0x251A / 0x246C / 0x2498，与 histb 板子页 boot log 逐字一致）
[观察·文档] Fastboot 3.3.0 版本打印 → Boot Media / DDR Size → MMC 初始化 → Boot Env on eMMC → SDK Version
[推断·显示] ★ GFX/higo 初始化（板子页 log 有 =====FILE: higo/adp_gfx.c 运行时打印；本 p1 只有该格式串）
            → 读 p5 baseparam 显示参数 + 读 p7 LOGO_TABLE → 点亮 HDMI/VO 并画 p7 图
[观察·文档] Security Begin Read RSA Key → Secure boot → ****** boot from kernel...******** → Starting kernel
```

**[推断]** 「通电立即显示」发生在 p1 fastboot 极早期、早于读 RSA key 与 `bootm` 内核；不是 env/命令触发（p02 `bootcmd=mmc read …; bootm …` 无显示动作），也不是 Linux 内核画的。**但 §1.2 证明本备份的 p1 内无该实现代码**，故显示环节标 [推断]、实现载体标 [未知]（§1.6）。用户已确认载体就是 p7 那张静态 JPEG（[观察]）。p5 `baseparam`：全部 `TIMING_*`=0、`VIRSCW/H=1280/720`、`HDMI0=(9,1,0)`、EDID 缓存 512 B 全 0（`docs/027 §4.7`）→ [推断] 时序运行时由 sink EDID 决定。

---

## 6. 【附录 E】已排除项

- **Android 开机动画**：`/system/media/bootanimation.zip`、`/system/bin/bootanimation`（p15 内有）、`desc.txt`/`part0/part1`、`SurfaceFlinger`/EGL、`/proc/msp/hifb0`、`boot.mp4`/`boot.ts` 全部跑在**完整 Android 用户态起来之后**（启动链最末段），而刷机过程只有 p1 hiboot（无内核、无 Android）。执行者/环境/时机完全不同 → **[观察] 排除，一句带过**。用户所说的「开机画面有动画」与「通电立即出静态图」是两个不同观察，不可混。
- **fastPlay**：[观察] p1 的 4 处 `fastplay` 中 2 处是 `blkdevparts` cmdline 里的**分区名**、2 处是 PDM 键 `fastplay`/`fastplaybak`/`playparam`（紧邻 `ERR: Can not find logo flash data!`，同为 0 引用 dead rodata）；`persist.sys.fastplay.exist` / `persist.sys.fastplay.fullyplay` 在 **p15（Android 属性）**；`p08_fastplay` 分区在本备份**全 0**。`fullyplay` 在 p1/p3/p11/p15 显示串集 **0 命中**。→ **[推断] fastPlay 不是 hiboot 极早期出图机制，排除**；[存疑] 若存在 p8 非空的原厂固件，其早期显示能力本备份无法分析。
- **pstore**：用户明确否定（刷前刷后都要正常系统、太复杂），不作方案。

---

## 7. 结尾一句话（team-lead 要求）

> **进度显示最简单的呈现方式 = `mw.l <显存地址> <ARGB> <count>` 直接把 32-bit 纯色填进正在被 VO 扫描的显存（不需要任何图片资源）；但还差的最基本事实是「显存物理地址（MMZ 运行时分配、静态不可知）」与「刷机分支 VO/HDMI 到底有没有初始化（实证：没有）」—— 在这条绘制链路坐实之前，唯一已实证、只改 `bootargs.bin` 就能给用户一个可判读渠道的，是 `docs/036 §4.2` 的「每步写阶段色块 logo 进 p5，卡死后正常开机显示」；真正「刷机过程中实时变色」得先解决 §1.2/§1.3 的 [未知]。**

---

## 8. 对象、工具、复现与合规

**[观察] 对象**（路径均为仓库内相对路径）：

| 对象 | 大小 | SHA-256 |
|---|---|---|
| `TMP/stock-rom-research/extracted/p01_fastboot.img` | 1,048,576 B | `bac0be9ff5926de1c813668216977c85e1903ceb3e69b83e5a7ffb2156b0c073` |
| `TMP/stock-rom-research/extracted/p07_logo.img` | 4,194,304 B | `cfc5db33166cbdf72577690b2d661647524c5138cf012ebdca52b2ed9f178ae6` |
| `TMP/stock-rom-research/extracted/p05_baseparam.img` | 4,194,304 B | `819fccdde59672a875cd6898f03f262d794860d25928478c839fda33ba8f8cdb` |
| `TMP/stock-rom-research/extracted/p03_recovery.img` | 16,777,216 B | `dcb4a24778adbc01241cafb08db6e0319177a7dd4f840df15f7e098b1c589074` |
| `TMP/stock-rom-research/extracted/p11_vmlinux.bin` | 17,432,904 B | `d43d57f4be2d7abbba3296b3011c3140111683bc7dd13c9bdeedd7e17a68d127` |
| `TMP/recovery-deep/recovery-vmlinux.bin` | 8,227,512 B | （`docs/035` 对象，kallsyms 已重建 35,937 符号） |
| `TMP/community-restore/fastboot.bin` / `mv100/fastboot.bin` | 539,264 / 539,272 B | `fd5b4ac6…` / `3bded87f…` |

工具：**capstone 5.0.7**（ARM A32 与 Thumb-2 双模式、`skipdata=True` 全文件）、**radare2 6.2.4**（`axt`/`pd`/`pxw`/`/x` 独立 oracle）、Python 3.14、macOS `sips`。链接基址 `0x00C00000`（1,706 指针投票验证）。

**复现产物（仓库内，均 gitignored）**：`TMP/stock-rom-research/display045/` 下 `scan_p1.py`/`p1-scan.log`/`p1-scan.json`（kallsyms/序言/bl 调用图/字面量/指针/命令表/MMIO）、**`pic_scan.py`/`pic_scan.log`/`pic_scan.json`（本轮新增：ARM+Thumb-2 的 PIC 相对引用盲区排除）**、**`code_data.py`/`code_data.log`/`code_data.json`（本轮新增：4 KiB 代码/数据分离、4 份二进制结构对照、fastplay/mw/MMIO 清单）**、`logo.py`/`logo.log`/`logo.json`、`recovery_elf.py`/`recovery_elf.log`/`recovery_elf.json`；`TMP/stock-rom-research/logo-extract/`（单张 JPEG + 512 B 表头）。

**边界**：全部为**只读静态分析**（外加 `docs/038` 已核实的公开文档级证据与 team-lead 转述的用户 [观察]），**未观察到运行时执行**；静态不写成「运行时执行了…」。「0 命中」一律读作「在指定对象/扫描方式/范围内未检索到」。结论按 `docs/033 §2` 标 `[观察]`/`[推断]`/`[未知]`/`[存疑]`；函数体/调用点结论均有反汇编或结构化证据；**不编造显存地址**。

**[未知] 项**：把 p7 JPEG 解码并写入 VO G0 图层的二进制是哪份、`G0_ADDR` 确切值、显存地址跨次上电是否稳定、p7 尾部 566 KiB 高熵数据性质、PIC 之外的其它间接引用形式。[存疑] 项：符号名池的具体生成机制、`docs/039` 的「hiboot 画 p5」归属（本轮 p1 无显示代码）、fastPlay 在 p8 非空固件中的角色。

**合规**：只读；不刷机、不改真机、不构建镜像、**不删除文件**、不用 `rm` / `git clean`、不访问项目目录之外的本地目录、不写入仓库外文件；临时产物全在 `TMP/stock-rom-research/` 下；文档不含本机绝对路径 / 用户名 / 卷名 / IP / 凭据，厂商构建机标识省略；**只改 `docs/045-stock-boot-display-mechanism.md` 一个文件**，未改动任何其它已跟踪文件，未执行 `git add` / commit / push / checkout / 建分支 / 动索引，由主会话统一提交。
