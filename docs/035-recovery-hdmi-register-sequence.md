# 035 — 原厂 Recovery HDMI 显示初始化链路逆向（固件实证）

> 2026-11-08。研究纲领：**以原厂 Recovery 为第一突破口**，逆向还原 HDMI 显示的
> 完整硬件初始化链路，最终移植到 ARMv7 主线 Linux；**不再以社区版 Linux 为研究基础**。
> 本文把 `docs/023 §4` 当年「因解不出 vmlinux 只能靠 SDK 推测」的内核侧空白，升级为
> **实际刷入固件的二进制实证**；hiboot 裸机部分压缩为最后一节，作为同 SDK 显示栈的交叉验证。
>
> **编号说明**：`docs/031` 固定为「hiboot / fastboot 裸机显示栈四问」（刷机执行者分析的直接证据，
> `docs/034` / `docs/036` 引用其 §2/§3/§4）；本文是 recovery 内核侧链路实证，单独编号 `035`。
> 两者是同一 SDK 显示栈的**内核侧**与**bootloader 侧**对照，不要互引数值。
>
> - 对象基线（SHA-256 见 `docs/033 §5`）：`TMP/recovery-deep/recovery-vmlinux.bin`
>   8,227,512 B / `d91d9104…`；`TMP/rec-zImage` / `a61d35da…`；`TMP/p3_recovery.img` / `a1609a50…`；
>   `TMP/community-restore/fastboot.bin` / `fd5b4ac6…`；`backup_stock/fastboot.img` / `bac0be9f…`。
>   `backup_stock/p01_fastboot_adb.img` 与 `fastboot.img` **SHA-256 相同**，是同一文件的两份拷贝，不作独立样本。
>   `TMP/p3_recovery.img` 的 `0x0` 与 `0x800000` 两个 boot.img 槽是**不同构建**（vmlinux 分别
>   8,227,512 B 与 7,539,320 B），数值不得互引。
> - 方法：**只读静态反汇编 + 符号/常量/交叉引用扫描**。本机唯一可用 ARM 反汇编器是
>   **capstone 5.0.7**（`Cs(CS_ARCH_ARM, CS_MODE_ARM | CS_MODE_LITTLE_ENDIAN)`，必要时 `skipdata=True`）；
>   Ghidra / IDA / radare2 / binwalk / ELF 工具均不可用，`/usr/bin/objdump` 不支持 ARM。
> - 地址基准：`0xC0008000`（`PAGE_OFFSET 0xC0000000` + `TEXT_OFFSET 0x8000`），
>   `docs/033 §4` 已由 `stext` 入口反汇编验证，本文所有 `bl` 目标 / 字面量 / 常量交叉引用统一用它。
> - 写作规范（`docs/033 §2`，逐条落实）：每条结论标 `[观察]` / `[推断]` / `[未知]`；
>   静态分析不写成「运行时执行了…」；「0 命中」只写「在 X 范围内未检索到」；
>   不靠 strings / 文件名 / 布局推断硬件行为；寄存器序列必须附**对象 SHA-256 + 地址 + 工具 + 反汇编片段**；
>   固件实证优先，SDK 推测只作交叉验证；同时看 `bootargs`（`mmz=`/`console=`）、`p05_baseparam`、
>   ramdisk 的 fb0 用法；对 `docs/032 §7` 七条逐条销账。

---

## 0. 结论总览

| 节 | 最关键一句 | 标记 |
|---|---|---|
| §2 HDMI 初始化链路 | [观察] 内核里没有 `HDMI_Display` 这个符号；等价硬件链路由 `hdmi_ProcessCmd` 分发 → `DRV_HDMI_Init` → `SI_HW_ResetHDMITX` → `SI_TX_PHY_INIT`，用 `SI_*` 前缀实现，`docs/023 §4.3` 的 hiboot 线性序列在内核侧**不是 1:1 对应**。 | [观察]+[推断] |
| §3 VO / Framebuffer | [观察] `DISP_Init` 把物理基址 `0xf8cc0000` 传给 `DISP_HAL_Init`，显存由 `DISP_OS_MMZ_Alloc → HI_DRV_MMZ_Alloc` 从 MMZ 分配，`HIFB_DRV_ModInit` 调 `register_framebuffer` 注册 fb；G0/GP0 层归属未能从本镜像定死。 | [观察]+[未知] |
| §4 EDID / 时钟 | [观察] EDID 走发射器自带 **MDDC**（`SI_BlockRead_MDDC` + `WriteByte_8BA`，非 GPIO bit-bang）；显示时钟是 `DISP_ResetCRG` 的 CRG 寄存器位操作，**未检索到直接 `bl clk_set_rate` 的调用点**。 | [观察] |
| §5 基址之辨 | [观察] 内核实际用 `0xF8CE1800`（由 `0x3E338600<<2` 算出）作 HDMI PHY 物理窗口，并经 `+0x05000000` 静态映射；`0xf8cc0000` 作 VO 物理基址。与 `docs/029` 的 `0x8ce0000` 相差 `0xF0000000`，疑为 DT 相对地址与 CPU 物理地址之差。 | [观察]+[推断] |
| §6 主线差距 | [推断] 主线要独立点亮 HDMI **并显示 TTY**，除复现上述初始化外还差：fbcon/VT 绑定、DRM/KMS 或 simplefb 接管、`reserved-memory`/CMA 对应 MMZ、clk/reset 的 DT 描述与主动 enable —— 原厂 recovery 只有「内核 hifb + 用户态 blit」，没有 fbcon。 | [推断] |
| §7 hiboot 交叉验证 | [观察] `logo`/`logobak` 不是 U-Boot 命令（是 PDM 参数键），`flashlogo` 只是写分区，刷机链无显示命令 + console 只有 `serial` → 「刷机时背光都不亮」与这两条路径一致。 | [观察] |

### `docs/032 §7` 七条待验证清单销账

| # | 问题 | 状态 | 结论（详见对应节） |
|---|---|---|---|
| 1 | `HDMI_DRV_ModInit` 等真实调用链 / 寄存器顺序，与 SDK 序列核对 | **answered** | §2：调用链由 kallsyms 定位；`SI_TX_PHY_INIT` 的 7 次写入有基址+偏移+值+顺序；SDK 线性序列不 1:1 对应 |
| 2 | `HI_DRV_DISP_Init` / `DISP_HAL_Init` 如何配 VO 图层、G0 还是 GP0 | **partially** | §3：`DISP_Init` 传 `0xf8cc0000` 已实证；`OPTM_GfxSetLayerAddr` 引用 `g_stGfxGPDevice`，但精确寄存器偏移未定，标 [未知] |
| 3 | hifb 注册 fb0 的显存来源 / 格式 / stride / 分辨率 | **partially** | §3：MMZ 来源与 `register_framebuffer` 调用点实证；格式/stride/分辨率未由本镜像定死（社区内核数值属另一对象，不互引） |
| 4 | 显示相关 clk 名、`clk_set_rate` 调用点、CRG 寄存器 | **partially** | §4：`DISP_ResetCRG` 位操作与 vendor clk helper 实证；`clk_set_rate` 直接调用点 0 命中；clk 名/CRG 位含义未解析 |
| 5 | `SI_ReadEDID` 走 DDC 还是 GPIO bit-bang | **answered** | §4：MDDC（发射器自带 DDC），`WriteByte_8BA` 经 MMIO 全局虚基址 4 字节 stride 访问 |
| 6 | 是否有可继承的 Bootloader framebuffer | **unresolved** | §7：hiboot 有 `LOGO_TABLE` 画 logo 能力，但 U 盘刷机路径不做显示初始化；能否被 simplefb 接管需真机验证 |
| 7 | `0xf8ce0000` / `0xf8cc0000` / `0xf9000000` 实际用途与 `docs/029` 对齐 | **partially** | §5：前两者有明确代码指向；`0xf9000000` 40 处命中全在数据区、未证实为 ioremap 基址；`0x8ce0000` 与 `0xf8ce0000` 关系标 [推断] |

---

## 1. 方法：如何在「无 ELF 符号表」的 vmlinux 里定位 HDMI 函数地址

这是本轮的核心方法突破，单列一节以符合 `docs/033 §2` 第 3、7 条（不把字符串地址当函数地址、pin baseline）。

### 1.1 起点约束（`docs/033 §4` 的观察，复核）

[观察] `TMP/recovery-deep/recovery-vmlinux.bin` 内 `kallsyms_addresses` / `kallsyms_names` /
`kallsyms_token_table` / `kallsyms_num_syms` / `/proc/kallsyms` 等字面串全部 0 命中；
`docs/032 §6.3` 扫到的 `HI_DRV_HDMI_Init` 等完整函数名来自 `__func__` / `EXPORT_SYMBOL` /
proc 接口名，**不是符号表条目**。因此「字符串所在地址」≠「函数地址」，不能直接拿来反汇编。

### 1.2 压缩 kallsyms 重建（脚本 `TMP/recovery-deep/kallsyms3.py`，可复现）

[观察] 在 `d91d9104…` 对象内定位到教科书式的 kallsyms 布局（`0xC0008000` 基准）：

| 结构 | 文件偏移 | 运行地址 | 内容 |
|---|---|---|---|
| `kallsyms_addresses[]` | `0x3DB6B8` | `0xC3DB6B8` | 35,935 个递增内核地址，首 `0xC0008000`、末 `0xC085A2F4` |
| `kallsyms_num_syms` | `0x3FE840` | `0xC3FE840` | `35937` |
| `kallsyms_names[]` | `0x3FE850` | `0xC3FE850` | 变长压缩名（1 字节 token 数 + token 索引） |
| `kallsyms_markers[]` | `0x466580` | `0xC466580` | 140 项递增偏移，用于校验 names 起点 |
| `kallsyms_token_table` | `0x4667C0` | `0xC4667C0` | 256 个 NUL 结尾 token（如 `ad_` `proc` `Get` `__`） |
| `kallsyms_token_index` | `0x466B40` | `0xC466B40` | 256 个递增 u16（0…891） |

[观察] 解码出 **35,937 条符号名**（如 `Tstext`、`t__create_page_tables`、`TSI_ReadEDID`），
names 起点由 140 个 markers 逐项校验通过。

[观察] **对齐修正**：`names[i]` ↔ `kallsyms_addresses[i-2]`（δ = −2）。两个独立 oracle 验证：
`__kstrtab_*` 自名字符串 **80/80** 命中、`__ksymtab_*` 的 `{value,nameptr}` 结构 **80/80** 命中；
`stext` 恰为 `0xC0008000`。未经此修正时（δ=0）只有 1/80 命中——这正是「不能靠猜」的实例。

### 1.3 定位结果（节选，`d91d9104…` / capstone 5.0.7）

| 函数 | 地址 | 函数 | 地址 |
|---|---|---|---|
| `HDMI_DRV_ModInit` | `0xC02E117C` | `HI_DRV_HDMI_Init` | `0xC02DDAA8` |
| `HDMI_ModeInit` | `0xC02E1058` | `HI_DRV_HDMI_Open` | `0xC02DD670` |
| `HDMI_DRV_Init` | `0xC02DDAA78` | `hdmi_ProcessCmd` | `0xC02DCD64` |
| `DRV_HDMI_Init` | `0xC02E54E4` | `SI_HW_ResetHDMITX` | `0xC02E9E24` |
| `SI_Start_HDMITX` | `0xC02E9910` | `SI_TX_PHY_INIT` | `0xC02ECB70` |
| `SI_ReadEDID` | `0xC02E8D0C` | `SI_ReadSinkEDID` | `0xC02E8E28` |
| `HI_DRV_DISP_Init` | `0xC0304464` | `DISP_Init` | `0xC0318078` |
| `DISP_HAL_Init` | `0xC02F02CC` | `register_framebuffer` | `0xC01D56C0` |

### 1.4 局限（必须保留）

[未知] 静态反汇编只能证明「镜像里存在这些指令 / 调用关系」，**不能证明运行时按此顺序执行**；
内核用 `HI_DRV_MODULE_Register` / `hdmi_ProcessCmd` 的 ops/ ioctl 分发，运行顺序取决于用户态
`/sbin/recovery` 下发的命令序列，本文不还原该时间线。
[未知] `kallsyms_addresses` 末 2 项为 0（对齐填充），本次只使用 `i-2 >= 0` 的符号。

---

## 2. HDMI 初始化链路（核心）

### 2.1 由符号表定位后逐函数反汇编得到的调用图（`d91d9104…`）

```
HDMI_DRV_ModInit (0xC02E117C)
 ├─ HDMI_ModeInit (0xC02E1058)
 │   ├─ hdmi_InitFmtArray / hdmi_Init_PixelClkArray      软件格式表 + 像素时钟表
 │   ├─ HI_DRV_DEV_Register / HI_DRV_PROC_AddModule       注册字符设备与 proc 接口
 │   └─ (无 MMIO 写入)
 ├─ HDMI_DRV_Init (0xC02DDAA78) ── DRV_HDMI_Register(0xC02DDDF74) ── HI_DRV_MODULE_Register
 └─ HI_LogOut / switch_dev_register（错误分支）

HI_DRV_HDMI_Init (0xC02DDAA8, 0x1C B) : 除 mcount 外仅一次 bl HDMI_DRV_Init  ← 薄转发壳，无 MMIO
HI_DRV_HDMI_Open (0xC02DD670)        : __memzero → hdmi_Open → hdmi_ExtIoctl×3
hdmi_ExtIoctl (0xC02DD214)           : down_interruptible → hdmi_ProcessCmd → up
HI_DRV_HDMI_ProcHotPlug (0xC02DD9D4) → hdmi_MCE_ProcHotPlug (0xC02DD7C4)
hdmi_MCE_ProcHotPlug : DRV_Get_SinkCap / DRV_Get_IsValidSinkCap /
                       DRV_Get_DefaultOutputMode / hdmi_ExtIoctl×3
```

[观察] `hdmi_ProcessCmd`（`0xC02DCD64`，0x4B0 B）是 **ioctl 命令分发器**，其 `bl` 目标包括
`DRV_HDMI_Init`(`0xC02E54E4`)、`DRV_HDMI_DeInit`、`DRV_HDMI_Open`、`DRV_HDMI_Start`、
`DRV_HDMI_Read_EDID`、`DRV_HDMI_SetFormat`、`DRV_HDMI_ReadEvent` 等。
→ **内核里不存在名为 `HDMI_Display` 的函数**（在 35,937 条符号中精确检索 0 命中）；
`docs/023 §4.3` 描述的 `HDMI_Display()` 是 **hiboot (`source/boot/product/driver/hdmi/hdmi_1_4/`)** 的实现，
内核侧等价功能被拆成 `DRV_HDMI_Init` / `SI_Start_HDMITX` / `SI_SetVideoPath` / `SI_EDIDProcessing` 等 `SI_*` 函数。

### 2.2 真正碰硬件的一段：`DRV_HDMI_Init` → `SI_HW_ResetHDMITX`

[观察] `DRV_HDMI_Init` (`0xC02E54E4`) 的 `bl` 目标（节选，capstone 解析）：
`DRV_Get_CommAttr`、`DRV_Get_ChnAttr`、`ReadByte_8BA`、`HI_DRV_MODULE_GetFunction`、
`SI_WriteBlockHDMITXP0`、`SI_HDMI_Setup_INBoot`（boot 态分支）、`DispFormatAdjust`、
`DRV_HDMI_Disp2UnfFmt`、`SI_Adjust_SwingCtrl`；
关键分支 `0xC02E5660` 起连续三条：

```
0xc02e5660  bl  #0xc02e9e24   -> SI_HW_ResetHDMITX
0xc02e5664  bl  #0xc02e9d18   -> SI_SW_ResetHDMITX
0xc02e566c  bl  #0xc02ecb14   -> SI_TX_PHY_PowerDown
```

随后 `SI_OpenHdmiDevice` / `SI_ReadBlockHDMITXP0` / `DRV_HDMI_SetDefaultAttr` /
`kthread_create_on_node(Hdmi_KThread_Timer)` / `SI_WriteDefaultConfigToEEPROM` / `hdmi_SetAndroidState`。

[观察] `SI_HW_ResetHDMITX` (`0xC02E9E24`) 的 `bl` 序列：
`SI_HW_ResetCtrl` → `SI_HW_ResetPhy` → `DelayMS` → `SI_HW_ResetPhy` → `DelayMS` →
`SI_TX_PHY_INIT` → `DelayMS` → `SI_HW_ResetCtrl` → `DelayMS` → `WriteByte_8BA` →
`DRV_Get_DDCSpeed` → `WriteByte_8BA` → `SI_Encoder_Adjust`。
`SI_SW_ResetHDMITX` (`0xC02E9D18`) 为
`SI_AssertHDMITX_SWReset` → `DelayMS` → `SI_ReleaseHDMITX_SWReset` → `DelayMS` → `ReadByte_8BA`。

### 2.3 寄存器写入序列（实证，附对象 / 地址 / 工具）

[观察] `SI_TX_PHY_WriteRegister` (`0xC02EC9E0`) 反汇编（`d91d9104…` / capstone 5.0.7）：

```asm
0xc02ec9f4  ldr  r3, [pc, #0xc]      ; lit@0xc02eca08 = 0x3e338600
0xc02ec9f8  add  r3, r0, r3          ; r3 = reg_index + 0x3e338600
0xc02ec9fc  lsl  r0, r3, #2          ; r0 = 4*(reg_index + 0x3e338600)
0xc02eca00  bl   #0xc02e6488        ; -> DRV_HDMI_WriteRegister
```

[观察] `DRV_HDMI_WriteRegister` (`0xC02E6488`) 全文：

```asm
0xc02e649c  add  r0, r0, #0x5000000
0xc02e64a0  str  r1, [r0]           ; 唯一的寄存器写
```

→ 物理窗口 `4 × 0x3E338600 = 0xF8CE1800`；内核以 `+0x05000000` 静态映射为虚拟地址
`0xFDCE1800`。[推断] 该 `0x05000000` 是本内核 I/O 静态映射偏移（由 `add` 与 `str` 直接得出，
但 DT `ranges` 未在本文内核中核对，故标推断）。

[观察] `SI_TX_PHY_INIT` (`0xC02ECB70`) 是唯一调用者 (`SI_HW_ResetHDMITX+0x3C`)，
其 7 次 `SI_TX_PHY_WriteRegister(reg_index, value)` 按出现顺序：

| 序 | reg_index | 物理偏移 | 物理地址 | 虚拟地址 | 写入值 |
|---|---|---|---|---|---|
| 1 | 0 | `+0x000` | `0xF8CE1800` | `0xFDCE1800` | 0 |
| 2 | 2 | `+0x008` | `0xF8CE1808` | `0xFDCE1808` | 2 |
| 3 | 3 | `+0x00C` | `0xF8CE180C` | `0xFDCE180C` | 2 |
| 4 | 4 | `+0x010` | `0xF8CE1810` | `0xFDCE1810` | 9 |
| 5 | 5 | `+0x014` | `0xF8CE1814` | `0xFDCE1814` | 4 |
| 6 | 6 | `+0x018` | `0xF8CE1818` | `0xFDCE1818` | 0 |
| 7 | 1 | `+0x004` | `0xF8CE1804` | `0xFDCE1804` | 1 |

反汇编原文（`0xC02ECB84`–`0xC02ECBD4`）：`mov r0,#0; mov r1,r0; bl` / `mov r0,#2; mov r1,r0; bl` /
`mov r1,#2; mov r0,#3; bl` / `mov r1,#9; mov r0,#4; bl` / `mov r1,#4; mov r0,#5; bl` /
`mov r1,#0; mov r0,#6; bl` / `mov r0,#1; mov r1,r0; bl`。
[观察] 这是本镜像里**唯一能完整列出「基址+偏移+值+顺序」的 PHY 初始化序列**；
其余 `SI_TX_PHY_*` 函数（`SI_Adjust_SwingCtrl`、`SI_TX_PHY_SetDeepColor`、`SI_TX_PHY_PowerDown`、
`SI_TX_PHY_EnableHdmiOutput`）都调用同一个 `SI_TX_PHY_WriteRegister`，但其值来自参数/状态，
静态反汇编不能确定运行时取值，**本文不编造**。

[观察] 另一类寄存器访问是发射器 byte 寄存器：`DRV_WriteByte_8BA` (`0xC02E6528`) 与
`DRV_ReadByte_8BA` (`0xC02E64D4`) 从全局 `g_VirHDMI_PHY_BASE_ADDR` (`0xC0847098`) 取虚拟基址，
`str r3, [r1, r2, lsl #2]` / `ldr r0, [r3, r2, lsl #2]` —— **4 字节 MMIO stride**；
设备码 `0x72` / `0x7A`（`0x7A` 时 reg 索引 `+0x100`，即第二 bank 偏移 `+0x400`），
与 `docs/029` 对 `sii9134.c`「三组 byte 寄存器 bank、4 字节 MMIO stride」的描述一致。

### 2.4 与 `docs/023 §4.3` SDK（hiboot）序列逐条核对

| SDK / hiboot 步骤（`docs/023 §4.3`） | 内核 vmlinux 实证 | 判定 |
|---|---|---|
| `HI_UNF_HDMI_Init()` 空壳，只打日志返回 | `HI_DRV_HDMI_Init` (`0xC02DDAA8`) 仅 0x1C B、一次 `bl HDMI_DRV_Init`，无 MMIO | [观察] 方向一致但严格说是**转发壳**，不是空壳；且这是内核函数，与 hiboot 同名函数不是同一实现 |
| `HI_UNF_HDMI_Open()` → `HDMI_Display()` | 内核无 `HDMI_Display` 符号；`HI_DRV_HDMI_Open` → `hdmi_Open`(0x28 B) + `hdmi_ExtIoctl` → `hdmi_ProcessCmd` | [观察] **不符**：内核走 ioctl 分发，不是单一 `Open→Display` |
| `GetSinkCapability()` 读 EDID | `SI_EDIDProcessing` → `SI_ReadSinkEDID` → `SI_ReadEDID` → `SI_BlockRead_MDDC`；`SI_ParseEDID` | [观察] 功能证实，函数名不同 |
| `UpdateTX_656` / `SetIClk(0)` / `WakeUpHDMITX` | 符号 `SI_UpdateTX_656`(`0xC02E758C`)、`SI_SetIClk`(`0xC02E96FC`)、`SI_InteralMclkEnable`(`0xC02E978C`) 存在；`SI_Start_HDMITX` 调 `SI_UpdateTX_656` / `SI_UpdateTX_DE` / `SI_SetDE` | [观察] 步骤存在，但顺序由 `SI_Start_HDMITX` 与 ioctl 决定 |
| AVI InfoFrame / VIC | `SI_GetAVIInfoFrameVID`、`DRV_HDMI_GetInfoFrame`、`DRV_HDMI_SetInfoFrame`、`hdmi_GetInfoFrame` | [观察] 符号证实；具体 VIC 值未由反汇编定值 |
| `TX_PHY_HighBandwidth` / `TX_PHY_SwingCtrl` | `SI_TX_PHY_HighBandwidth`、`SI_Adjust_SwingCtrl`（`DRV_HDMI_Init` 调用） | [观察] 证实 |
| `TX_SetHDMIMode` | `SI_TX_SetHDMIMode`(`0xC02E96A0`)，由 `SI_Start_HDMITX` / `SI_Init_DVITX` 调用 | [观察] 证实 |
| `TX_PHY_EnableHdmiOutput()` 最后打开输出 | `SI_TX_PHY_EnableHdmiOutput`(`0xC02ECBDC`) → `SI_TX_PHY_ReadRegister` + `SI_TX_PHY_WriteRegister` | [观察] 函数存在；「最后一步」的运行时次序未证实 |

[推断] 两者是**同一套 HiSTB SDK 显示栈在不同软件层（hiboot vs Linux 内核）的实现**：
硬件步骤大体对应，但内核把它拆成「模块注册 + ioctl 分发 + `SI_*` 驱动」，
不能把 `docs/023 §4.3` 的线性序列直接当作内核调用顺序抄进主线驱动。

---

## 3. 显示控制器 / VO / Framebuffer

### 3.1 DISP 初始化与 VO 基址（实证）

[观察] `HI_DRV_DISP_Init` (`0xC0304464`) → `DISP_Init` (`0xC0318078`)；
`DISP_Init` 的 `bl` 目标：`DISP_HAL_Init`、`DISP_HAL_GetOperation`、`DISP_HAL_GetVersion`、
`DISP_DA_Init`、`DispInitDisplay`×2、`DISP_ISR_Init`、`request_threaded_irq`、
`DispResetHardware`、`DRV_PQ_UpdateVdpPQ`、`DISP_Open`、`DispGetHdmiFunction`。

[观察] `DISP_Init+0x48` 处的两条指令（`d91d9104…` / capstone）：

```asm
0xc03180c0  ldr  r0, [pc, #0x1a4]   ; lit@0xc031826c = 0xf8cc0000
0xc03180c4  bl   #0xc02f02cc        ; -> DISP_HAL_Init
```

→ `0xf8cc0000` 作为**参数**传给 `DISP_HAL_Init`，与 `docs/023 §4.2` 的
`CONFIG_VDP_REG_BASEADDR = 0xf8cc0000` 一致（固件实证，不再是 SDK 推测）。

[观察] `DISP_HAL_Init` (`0xC02F02CC`) 的 `bl`：`Chip_Specific_DISP_OpenClock`、
`DISP_OS_MMZ_Alloc`、`DispGetVersion`、`DISP_HAL_InitVDPState`，并把一批 `PF_*`
函数指针填入全局 `s_stDispCapability` (`0xC084C870`)。
`DISP_OS_MMZ_Alloc` (`0xC030C458`) → `HI_DRV_MMZ_Alloc` (`0xC02B3EF4`)；
`hifb_buf_allocmem` 也 3 次调用 `HI_DRV_MMZ_Alloc` → **显存来自 MMZ**。

[观察] VO 寄存器访问机制：`VDP_DRIVER_SetVirtualAddr` (`0xC02F2B1C`) 把 ioremap 后的
虚拟地址存入全局 `pVdpReg` (`0xC084D030`)；`VDP_RegWrite` (`0xC02F2B5C`) 与
`OPTM_VDP_RegWrite` (`0xC0325510`) 都只是 `str r1, [r0]`。
→ 内核热路径**不出现物理基址字面量**，这解释了 §5 里 `0xf8cc0000` 只有 2 处命中。

### 3.2 G0 还是 GP0（部分结论，标未知）

[观察] `HIFB_DRV_SetLayerAddr` / `SetLayerStride` / `UpdataLayerReg` 都是薄封装：
从全局 `g_stGfxOps` (`0xC0857A40`) 取函数指针（`+0x18` / `+0x1c` / `+0x54`）后间接调用；
`HIFB_DRV_GfxInit` → `OPTM_GFX_GetOps`。
[观察] `OPTM_GfxSetLayerAddr` (`0xC032A544`) 引用全局 `g_stGfxGPDevice` (`0xC08564D4`)
并调用 `OPTM_VDP_GFX_SetLayerAddrEX` (`0xC032912C`) → `OPTM_VDP_RegWrite`；
符号表另有 `VDP_GFX_SetLayerAddr`、`VDP_GFX_SetLayerNAddr`、`OPTM_VDP_GFX_SetLayerStride` 等。

[未知] 精确图层寄存器偏移（`G0_ADDR +0x494` / `GP0 = G0+0x800`，`docs/023 §4.2`）**未能由本镜像
反汇编定死**：`OPTM_GfxSetLayerAddr` 中的个别 word 被 capstone 解成可疑的
`str r1, [r2, #0xa30]`，疑为字面量池/内联数据，未据此下结论。
`docs/023 §5.3` 的「G0 还是 GP0/WBC」问题维持 **unresolved**，需真机或 SDK 头文件核对。

### 3.3 hifb 注册 fb0（实证）与分辨率（未知）

[观察] `register_framebuffer` (`0xC01D56C0`) 在 vmlinux 中**只有 1 个调用者**：
`HIFB_DRV_ModInit+0x458` (`0xC0339360`)，其前文 `fb_alloc_cmap`、`hifb_buf_map`、
`str r0,[r4,#0x230]`（保存映射地址）。ramdisk `/sbin/recovery` 用
`open("/dev/graphics/fb0")` + `FBIOGET_*SCREENINFO` + `KDSETMODE/KD_GRAPHICS` 直接 blit
（`docs/023 §3`）；vmlinux 内 `/dev/graphics/fb0`、`KDSETMODE`、`KD_GRAPHICS` 字符串各 1–2 处命中。

[未知] 像素格式 / stride / 分辨率**未由本镜像定死**：`docs/023 §5.1` 的
`1920x1080 ARGB8888 / stride 7680 / smem_start 0x3c55c000` 来自**社区 Ubuntu 内核**（另一对象），
按 `docs/033 §2` 第 7 条不得与 `d91d9104…` 互引。主线侧需自行确定或验证。

---

## 4. EDID / HPD / 时钟 / 复位

### 4.1 EDID 走发射器自带 MDDC（answered）

[观察] `SI_EDIDProcessing` (`0xC02EBEC0`) 的 `bl` 序列：
`SI_HPD_Status` → `SI_ReadSinkEDID` → `SI_HPD_Status` → `SI_timer_count` →
`SI_ParseEDID` → `SI_AssignOutputState`（失败回退 `SI_AssignDefaltOutputState`）。

[观察] `SI_ReadSinkEDID` (`0xC02E8E28`) → `SI_DDC_ResetTV` → `SI_ReadEDID`×2 →
`GetExtBlockNum` / `BlockCheckSum`；`SI_ReadEDID` (`0xC02E8D0C`) →
`DRV_Get_IsUserEdid`（用户覆写 EDID 分支 `DRV_Get_UserEdid`）→ `WriteByte_8BA` →
`SI_BlockRead_MDDC` (`0xC02EBA34`)。
[观察] `SI_BlockRead_MDDC` 内：`WriteByte_8BA(1, 0x72, 0xF3, 9)`、
`SI_BlockWriteHDMITXP0(0xED, 7, buf)`、轮询 `ReadByte_8BA(1, 0x72, 0xF2)` 的 bit4、
`SI_BlockReadMDDCFifo`、`ConvertMDDCStateIntoErrCode`，并写 `0xF3=0xF / 0xA`、`0xEC` 收尾。

→ [观察] **EDID 通过 SiI9134 发射器自带的 Master DDC（MDDC）经 MMIO byte 寄存器读取**，
不是 GPIO bit-bang I2C。`hi_gpio` 字符串 22 处命中中，字面量交叉引用只定位到
`GPIO_DRV_ModInit`（通用 GPIO 驱动）；`/dev/hi_i2c` 字符串 1 处命中，
在本次 capstone 全文件 `ldr[pc]` 扫描范围内**未检索到显示路径对它的引用**。
[推断] 主线侧对应 `drm_edid` + bridge 的 DDC（或 SiI9134 自带 DDC），
而不是 `i2c-gpio` bit-bang —— 与 `docs/029`「HDMI block keeps the DDC pins to itself」一致。

### 4.2 HPD（观察）

`SI_HPD_Status`、`hdmi_MCE_ProcHotPlug`、`HI_DRV_HDMI_ProcHotPlug`、`Hdmi_KThread_Timer`
（由 `DRV_HDMI_Init` 用 `kthread_create_on_node` 创建）、`hdmi_ProcEvent` 均存在于符号表；
`hdmi_MCE_ProcHotPlug` 通过 `hdmi_ExtIoctl` 下发，并读 `DRV_Get_SinkCap` /
`DRV_Get_DefaultOutputMode`。[未知] 具体中断/轮询时序未还原。

### 4.3 时钟与复位（partially）

[观察] `DISP_HAL_Init` → `Chip_Specific_DISP_OpenClock` (`0xC02F1E5C`) → `DISP_ResetCRG` (`0xC02F77A4`)；
后者从全局 `g_pstRegCrg` (`0xC07D1730`) 取基址，对 `[r3, #0xD8]` 做
`orr #0x7f` / `bfc` / `bfi` / `orr #0x4100000` / `orr #0x40000000` 等位操作后写回
—— 这是**CRG 寄存器偏移 +0xD8** 的时钟/复位配置（值由运行时状态与位域组合决定，本文不编造最终值）。
[观察] 其它时钟相关符号：`VDP_VDAC_SetClk`、`VDP_DISP_SetHdmiClk`、`VDP_SelectClk`、
`VDP_SetClkGateEn`、`VDP_CloseClkResetModule`、`MakePixClkParaInteger`、
`hdmi_Init_PixelClkArray`、`DRV_Calculate_TMDSCLK`、`SI_SetMCLK` / `SI_SetIClk` /
`SI_InteralMclkEnable`、`DRV_HDMI_SetPhyAudioClk`；字符串 `mach-hi3798mx/clock.c`、
`enable clock:%s failed` 各 1 处命中。
[观察] `clk_set_rate` (`0xC0018190`) 存在于符号表，但在**全文件 raw ARM `bl` 解码**
（`0xEB……` 指令，逐 word 计算目标）范围内 **0 个直接调用点**；
`clk_enable` / `clk_disable` 的调用者均为 pl011 / sp804 / hinfc / pm_clk 等通用路径，
未见显示驱动直接调用。

[推断] 对主线而言，`clk_ignore_unused` 只是「别关掉」的权宜之计，
**不足以**替代「主动 `clk_get/enable` + CRG reset 描述」；`docs/023 §5.3`、
`docs/025 §1.3` 的 SDM845 教训同向。需按 `docs/029` 的 `400-01` / `400-02` CRG 驱动
在 DT 里描述 HDMI ctrl/phy clock 与 base/bus/phy reset。
[未知] 具体 clk 名与 CRG 位含义未从本镜像解析（需 SDK `clock.c` / CRG 头或 DT 对照）。

---

## 5. 基址之辨（与 `docs/029` 对齐）

[观察] 对 `d91d9104…` 全文件做 4 字节小端字面量扫描（`TMP/recovery-deep/mmio_xrefs.py`）：

| 常量 | 命中 | 代码级 `ldr[pc]` 引用位置 | 判定 |
|---|---|---|---|
| `0xf8cc0000` | 2 | `PQ_HAL_IsVdpReg+0x18`（`cmp` 比较，判断地址是否 VDP 寄存器区）；`DISP_Init+0x48`（作参数传给 `DISP_HAL_Init`） | [观察] VO/VDP **物理基址**在内核中实证使用 |
| `0xf8ce0000` | 1 | `HDMI0_Proc+0xF88`（proc/调试转储路径） | [推断] HDMI TX 物理基址经 ioremap 存入全局（如 `g_VirHDMI_PHY_BASE_ADDR`），热路径用虚拟地址 |
| `0xF8CE1800` | 由 `0x3E338600<<2` 算出 | `SI_TX_PHY_WriteRegister+0x14` → `DRV_HDMI_WriteRegister` | [观察] HDMI PHY 寄存器窗口，7 次写入见 §2.3 |
| `0xf9000000` | 40 | 多数落在数据区（`initcall` 表、`kern_table`、`hid_usage_table` 等），**本次全文件 `ldr[pc]` 扫描未检索到把它当基址加载的代码** | [未知] 不能据命中数推断为 ioremap 基址 |
| `0x08ce0000` | 0 | — | 在 `d91d9104…` 全文件字节范围内**未检索到**；按 `docs/033 §2` 第 2 条，不得据此推出「不存在」 |
| `0xf8ab0000` | 3 | initcall 区（`__con_initcall_*` 别名区间）3 处 `ldr[pc]`，随后 `[r3,#0x84]` 等访问 | [推断] CRG/时钟复位寄存器窗口（与 `g_pstRegCrg` 位操作同向） |

[观察] 内核把 `0xF8CE1800` 经 `+0x05000000` 变为 `0xFDCE1800` 再 `str`（§2.3），
是「CPU 物理地址 → 内核静态映射虚拟地址」的转换。

[推断] `docs/029` 的 mv100 DT `reg = <0x8ce0000 0x10000>` 与固件里的 `0xF8CE0000` 相差
**恰好 `0xF0000000`**；这更像「DT 相对地址 + 父总线 `ranges` 基址 = CPU 物理地址」的两种表示，
而非 `docs/029` 所警惕的「把 hi3716cv200 的地址误当 mv100」。
本文**不推翻 `docs/029`**（其 bridge 链路结论仍为基线），只把这条算术关系列为待核对项：
需读 `910-01` 的 `ranges` / `500-01` binding 原文确认，标 [推断]。

[观察] 前缀证据：符号表中 `SI_` 前缀 **157** 个、`SI_TX_PHY` 11 个；
`SII_` / `SiI_` / `sii` 在符号名中 0 命中；字符串 `sii9134` 在 `d91d9104…` 全文件 0 命中。
按 `docs/033 §2` 第 2 条，**「`sii9134` 字面量 0 命中」不能推出「没有该 IP」**；
`SI_ReadEDID` / `SI_BlockRead_MDDC` / `SI_TX_PHY_*` 与 hiboot 的 `siiSetVideoPath` /
`SiI_DeepColor_*` 共同说明 SDK 用 `SI_`/`SiI_` 前缀封装 Silicon Image 发射器 IP，
**补强 `docs/029` 的 SiI9134 bridge 结论**，不重复 `docs/027 §6` 那个已撤销的误判。

---

## 6. 主线 Linux 要独立点亮 HDMI 并显示 TTY，还差什么

[观察] 原厂 recovery 的「能显示」= 内核 `HIFB_DRV_ModInit` 注册 `fb0`
+ 用户态 `/sbin/recovery` 直接 blit PNG；**内核侧没有 fbcon/VT**：
`fbcon` / `console=tty0` / `vt_console` / `fbcon_start` 在 vmlinux 字符串中均 0 命中，
`register_console` 只有 1 个调用者 `uart_add_one_port`（串口），
cmdline 痕迹只有 `console=ttyAMA0,115200` 与 `ttyMTD,blackbox`（`docs/032 §6.4`）。

[推断] 因此主线要**独立**点亮 HDMI 且显示控制台文字，除复现 §2–§5 的初始化外，还差：

| 环节 | 原厂做法（实证） | 主线需要补 |
|---|---|---|
| 显示引擎 / HDMI TX / PHY | `DISP_Init` + `DRV_HDMI_Init` + `SI_*`（私有驱动，内建） | DRM/KMS 驱动（`docs/029` 的 `500-01/500-02/600-*` bridge 链路）或最小 fbdev 驱动；6.x 无这些私有驱动 |
| Framebuffer → 文字 | 无 fbcon；用户态 blit | `CONFIG_FB` + `FRAMEBUFFER_CONSOLE` + `VT` + `console=tty0`，并把 framebuffer 绑定到 fbcon（或 DRM fbdev  emulation） |
| 显存 | `mmz=ddr,0,0,256M/380M` + `HI_DRV_MMZ_Alloc` + `DISP_OS_MMZ_Alloc` + `hifb_buf_allocmem` | `reserved-memory` + `no-map` / CMA（`media_cma`），与 `mmz` 语义对齐；`docs/025 §1.3` 明确 `no-map` 否则 ioremap 会 panic |
| 时钟 / 复位 | `DISP_ResetCRG` 位操作 + vendor clk helper；未见 `clk_set_rate` 直接调用 | CRG 驱动（`400-01/400-02`）+ DT `clocks`/`resets` + 主动 `clk_get/enable`；`clk_ignore_unused` 不够 |
| EDID / HPD / DDC | 发射器自带 MDDC（非 GPIO I2C） | bridge 的 DDC / `drm_edid`；`500-02` 的 master DDC 或 `910-02` 的 `i2c-hdmi` 需按固件实证择一 |
| 基址 | 物理 `0xf8cc0000`(VO) / `0xF8CE1800`(PHY)，`+0x05000000` 静态映射 | 按 `docs/029` 的 DT `reg = <0x8ce0000 0x10000>` 与 `ranges` 核对，不照抄 SDK `0xf8ce0000` |
| Bootloader 遗留 framebuffer | hiboot 正常开机画 `LOGO_TABLE` logo；**U 盘刷机路径不画**（§7） | simplefb「cont-splash 接管」只在确有遗留帧缓冲时成立；刷机/首次启动路径不能依赖它 |

[推断] 与 `docs/032 §4` 验收标准的对应：主线必须**自己**完成上述初始化并绑定 fbcon，
不能用 hiboot 静态 logo 冒充 HDMI 输出；无串口硬件下只能用 HDMI 画面 / pstore / SSH 验证。

---

## 7. hiboot 交叉验证（同一 HiSTB SDK 显示栈，压缩保留）

[观察] 对象 `backup_stock/fastboot.img`（`bac0be9f…`，与 `p01_fastboot_adb.img` 同文件）
与 `TMP/community-restore/fastboot.bin`（`fd5b4ac6…`）均为 ARM U-Boot 派生镜像，
链接基址 `0x00C00000`（向量表 + 1706/1310 个字符串指针命中，见
`TMP/stock-rom-research/hiboot-disasm/`）。两镜像共用同一套 SDK 显示栈，
可与内核侧 `SI_*` / `VO` 证据互相印证。

- **`logo` / `logobak` 不是 U-Boot 命令**：[观察] `cmd_tbl_s`（28 B 步长，
  原厂表 `0x93A2C`、社区表 `0x801EC`）分别含约 45 / 54 个命令
  （`go` `reset` `bootm` `fatload` `mmc` `run` `crc32` `saveenv` `otp_*` …），
  **不含 `logo` / `logobak`，也无任何显示命令**；两串在任意对齐位置的 4 字节指针
  在 4 份构建中均 0 命中。相邻字符串 `LOGO_TABLE` / `LOGO_KEY_FLAG` / `LOGO_KEY_LEN` /
  `there is no logo param!` / `PDM_ReadLogoParam` 表明它们是 **PDM 参数键**，非命令。
  → `bootcmd` 里**没有可插入的写法**；`flashlogo=run loadfilel flashpartitionl` 只是
  `fatload + mmc write` 写 logo 分区，不触发显示。
- **`PRODUCT_DisplayInit` / `Logo_Main` 调用时机**：[观察] 它们在 hiboot 里是函数名字符串，
  在 4 份构建中做全量交叉引用（ARM/Thumb 字面量、`movw/movt`、PIC 修正、备用基址、
  `skipdata=True` 全文件）均为 0 命中 → **调用点未能定位，标 [未知]**，不下断言。
  [观察] 三份 `bootargs.bin`（CRC 全通过）全部 `stdin=stdout=stderr=serial`、
  `bootdelay=0`，`bootcmd` 全是 `run flash*` + `fatload/mmc write/crc32/reset`；
  hiboot 命令表与字符串里 `vidconsole` / `vesa` / `cfb_console` / `lcd` / `nulldev`
  在检索范围内 0 命中，console 设备注册路径只有 `serial`。
  → [推断] 用户「刷机时显示器背光都不亮」对应这条 **U 盘 `fastboot.bin` + `bootargs.bin` 路径**：
  它既不刷新 HDMI，也没有视频 console 入口；用户看到的 "Debian Linux" 画面是
  logo 分区在（另一次）正常开机路径被画出，不是刷机进度。
- **与内核侧对照**：[观察] hiboot 含 `HDMI_Display`、`siiSetVideoPath`、`SiI_DeepColor_*`、
  `ConfigTXVideoMode`、`TX_PHY_*`、`PRODUCT_DisplayInit`、`Logo_Main`、`LOGO_TABLE`，
  与内核 `SI_ConfigTXVideoMode` / `SI_SetVideoPath` / `SI_TX_PHY_*` / `DISP_Init` 同名同族，
  印证二者共用 HiSTB SDK 显示栈；hiboot 的 `TX_PHY_*` 与内核 §2.3 的 PHY 序列属同一硬件窗口。
  [观察] 4 份 hiboot 镜像内 `0x8ce0000` / `0xf8ce0000` / `0xf8cc0000` 的 4 字节字面量
  在检索范围内均 0 命中 —— 与内核「热路径用 ioremap 后的虚拟地址」同构。
- **对「bootloader 遗留 framebuffer 能否被主线接管」的结论**：
  [推断] 只有在「确有 hiboot 画 logo 且留下 VO 图层寄存器的那次开机」才可能用
  simplefb 交接；**U 盘刷机/首次启动路径不满足该前提**（§7 第二条）。
  这与 `docs/023 §5.2` 第一阶段「保留 hiboot 状态」的适用边界一致，也解释了为何
  `patches/kernel/hi3798mv100-hdmi-console.c` 读 `VO_G0_ADDR` 的方案在刷机路径上可能读空。

---

## 8. 复现台账、证据边界与合规

| 产物（仓库内相对路径，均 gitignored） | 用途 |
|---|---|
| `TMP/recovery-deep/kallsyms.py` / `kallsyms2.py` / `kallsyms3.py` | 压缩 kallsyms 重建；`kallsyms3.py` 为最终版（δ=−2，双 oracle 验证） |
| `TMP/recovery-deep/kallsyms-symbols.json` / `kallsyms3.log` | 35,937 条符号（名 + 地址） |
| `TMP/recovery-deep/disasm.py` | 符号感知 ARM 反汇编（`bl` 目标解析、字面量 / `movw/movt` / `str` 标注） |
| `TMP/recovery-deep/disasm-hdmi-corrected.log` / `disasm-disp.log` / `disasm-hw.log` / `disasm-regwriters.log` / `disasm-final.log` | 各函数反汇编原文 |
| `TMP/recovery-deep/mmio_xrefs.py` / `mmio-xrefs.log` / `mmio-xrefs.json` | MMIO 基址字面量与代码级 `ldr[pc]` 交叉引用 |
| `TMP/recovery-deep/queries.py` / `queries.log` | raw `bl` 调用点扫描、符号前缀、console / DDC / 时钟字符串 |
| `TMP/stock-rom-research/hiboot-disasm/scan.py` / `scan.log` | hiboot 命令表 / 字符串 / xref（§7） |

**证据边界（逐条声明）**：

- 本文所有「调用链」「寄存器写入」均来自 `d91d9104…` 的 capstone 5.0.7 反汇编与
  重建 kallsyms 表，标注了对象 SHA-256、运行地址、工具；**未观察到运行时执行**，
  「顺序」指镜像中指令/`bl` 的出现顺序（§2.3 的 7 次写入为函数体内顺序）。
- 「0 命中」一律指「在指定对象 / 指定扫描方式 / 指定范围内未检索到」，
  不推出「硬件上不存在」；`sii9134` 与 `0x08ce0000` 的 0 命中即按此处理（§5）。
- 未由本镜像定死的项一律标 `[未知]` / `unresolved`：G0/GP0 精确偏移、fb 格式/stride/分辨率、
  `clk_set_rate` 间接调用、`0xf9000000` 用途、bootloader framebuffer 可继承性。
- 跨对象数值不互引：社区 Ubuntu 的 fb 几何（`docs/023 §5.1`）、整机备份的
  `p05_baseparam`（`docs/027 §4.7`，来自 `TMP/stock-partition-backups/` 分卷，属**另一对象**）
  仅作背景；`mmz=ddr` / `console=` 在 `d91d9104…` 内的字符串命中为本对象证据。
- SDK 序列（`docs/023 §4.3`）只作交叉验证；冲突处以固件为准（§2.4）。

**合规**：只读静态分析；不刷机、不改真机、不联网、不构建镜像、不删除文件、
不用 `rm` / `git clean`、不访问项目外目录；临时产物全在 `TMP/`；
文档不含本机绝对路径 / 用户名 / 卷名，厂商构建机路径与构建用户标识一律省略；
只新建 `docs/035-recovery-hdmi-register-sequence.md` 一个文件，未改动任何已跟踪文件，
未执行 `git add` / commit / push / checkout / 建分支 / 动索引，由主会话统一提交。
