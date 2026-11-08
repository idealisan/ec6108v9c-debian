# 035 — recovery vmlinux 真实 MMIO 寄存器写入序列（固件实证）

> 2026-11-08。承接 `docs/031`（hiboot 负结果）、`docs/034`（recovery vmlinux 代码可达、
> 但寄存器写入表仍 `[未知]`）与 `docs/032 §7`（七条待验证清单）。
> 本文执行 `docs/034 §5.1` 的最高价值一步：**追 `s_stDispCapability+0x258` 的读取点、
> 还原真实的 MMIO 寄存器写入**，并把 `docs/032 §7` 逐条回销。
>
> 版本说明：本文件在 HEAD 中曾为上一轮「recovery HDMI 初始化链路逆向」文档
> （commit `c8ae8ff`）。本轮按主会话指定的同一路径覆写为「寄存器写入序列」；
> 上一版的方法（§1 kallsyms 重建）与调用链（§3）已在本文中保留并深化，
> 完整旧文仍在 git 历史中可取回。
>
> **编号分工**：`docs/031` 固定为「hiboot / fastboot 裸机显示栈四问」（刷机执行者分析的
> 直接证据，`docs/034` / `docs/036` 引用其 §2/§3/§4）；本文 `docs/035` 是 recovery 内核侧
> 寄存器序列实证。hiboot 侧的交叉验证结论仍以 `docs/031` 为准，两文不互引数值。
>
> - 对象：`TMP/recovery-deep/recovery-vmlinux.bin`，8,227,512 B，
>   SHA-256 `d91d91049db9893c5a5811826b73a79e58f82330a669729bee58713706ac6e7d`
>   （由 `TMP/rec-zImage` 的 xz piggy @`0x391f` 解出，见 `docs/032 §6`）。
>   镜像 VA 覆盖 `0xC0008000 .. 0xC07E0AB8`，**此后的全局在 BSS**（运行时初始化）。
> - 链接地址 `0xC0008000`（`docs/033 §4` 已验证）；本文所有指令 VA / 全局 VA 均按此。
> - 工具：**radare2 6.2.4**（`r2 -a arm -b 32 -m 0xC0008000 -q -c 'pd N @ ADDR'`）
>   + **capstone 5.0.7**（`Cs(CS_ARCH_ARM, CS_MODE_ARM|CS_MODE_LITTLE_ENDIAN)`，`skipdata=True`），
>   关键片段逐条互验（`docs/033 §2` 第 7 条独立 oracle）；Python 3.14.6。
> - **额外 oracle**：上一轮已重建本镜像的压缩 kallsyms 表（`TMP/recovery-deep/kallsyms3.py`，
>   `δ=−2`，`__kstrtab_*` / `__ksymtab_*` 各 **80/80** 验证，`stext=0xC0008000`），
>   得 **35,937 条精确函数地址**。因此本文**直接按符号表定位函数体**，不依赖字符串地址推断
>   （这正是 `docs/033 §4` 要求、且比「从指针引用回溯函数边界」更可靠的一条）。
> - 规范（`docs/033 §2`）：每条结论标 `[观察]` / `[推断]` / `[未知]` / `[存疑]`；
>   静态分析不写「运行时执行了…」；「0 命中」只写「在 X 范围内未检索到」；
>   寄存器写入必须附对象 SHA-256、指令 VA、工具与反汇编片段；不编造寄存器值。

---

## 0. 结论先行

| 级别 | 结论 |
|---|---|
| **[观察]** | **是否拿到可验证的 MMIO 寄存器写入表：是（分层、带边界）。** 拿到「基址来源 → 偏移 → 写入指令 VA → 写入值 / 来源寄存器」表（§2.3），由 capstone 全量 taint + radare2 逐条互验。但**绝大多数写入值是运行时读改写（RMW），不是静态常量**；只有 **HDMI PHY 的 7 次写入**与 **HDMI 复位 CRG 的少数写入**有编译期静态值。本文不把 RMW 伪造成定值。 |
| **[观察]** | 三条虚拟 MMIO 基址闭环实证：VO `0xfdcc0000`（`0xf8cc0000 + 0x5000000`）、HDMI TX `0xfdce0000`、CRG `0xfda22000`（`g_pstRegCrg` 的 `.data` 静态值）。`docs/034 §3.2` 的「+0x258 缓存虚拟地址」推断被证实并追到了读取者。 |
| **[观察]** | 显示驱动的**统一写入口**是 `VDP_RegWrite`(`0xc02f2b5c`, `str r1,[r0]`，592 个调用者)、`OPTM_VDP_RegWrite`(`0xc0325510`, 131 个) 与 `DRV_HDMI_WriteRegister`(`0xc02e6488`, 2 个)；地址由调用方用 `*pVdpReg` / `*g_VirHDMI_PHY_BASE_ADDR` / `*g_pstRegCrg` 加偏移算出。这解释了 `docs/034 §2.1`「基址常量只有 1–2 次、不邻接 str」。 |
| **[观察]** | `clk_set_rate`(`0xc0018190`) 在全文件 raw `bl` 解码范围内 **0 个直接调用点**；显示时钟走 `g_pstRegCrg` 的 CRG 寄存器位操作 + vendor helper。EDID 走发射器自带 MDDC，不是 GPIO bit-bang I2C。 |
| **[存疑]** | 这份 3.10 内核里 `0xf8ce0000` 被代码使用、`0x08ce0000` 在镜像全文件字节范围内 0 命中，与 `docs/029`「mv100 DT `0x8ce0000`、`0xf8ce0000` 属 hi3716cv200」存在张力。二者相差 `0xF0000000`，疑为 **DT 相对地址 + 父总线 `ranges` = CPU 物理地址**的两种表示（§5.3），但本文**不据此推翻 `docs/029`**——`docs/027 §6` 正因同类推断被撤销。 |
| **[未知]** | `docs/023 §4.2` 的 `G0_ADDR +0x494` / `G0_STRIDE +0x49c` / `G0_IRESO +0x4a0` 与 GP0/G0 层归属**仍未由本镜像定死**；本镜像的 `VDP_VID_SetLayerEnable` 用的是 `+0x800 + layer*0x800` 的 VID 层块，二者不是同一寄存器组，不得互推。 |

---

## 1. 方法：函数地址怎么定（以及 lead 给的指针引用点是什么）

### 1.1 kallsyms 重建（上一轮成果，本轮复用并复核）

[观察] 在 `d91d9104…` 内定位 `kallsyms_addresses[]`@`0x3DB6B8`（35,935 项）、
`kallsyms_num_syms`@`0x3FE840`(35937)、`kallsyms_names[]`@`0x3FE850`、
`kallsyms_markers[]`@`0x466580`(140 项)、`kallsyms_token_table`@`0x4667C0`、
`kallsyms_token_index`@`0x466B40`；解码出 35,937 条符号名。
[观察] 对齐 `names[i] ↔ addresses[i-2]`（δ=−2），双 oracle 各 80/80 命中，`stext=0xC0008000`。
→ 函数地址是**符号表实测**，不是「字符串地址 = 函数地址」的推断。

### 1.2 lead 给的 4 个指针引用点解析（回答「回溯函数边界」）

[观察] 逐点回读（capstone + 符号表 owner）：

| 字符串 | 引用点（文件偏移 → VA） | 该 VA 的内容 | 判定 |
|---|---|---|---|
| `DRV_HDMI_Read_EDID` | `0x2db66c` → `0xc02e366c` | `0xc03d975c`（指向函数名串） | 落在 **`DRV_HDMI_Read_EDID`(0xc02e35c8)+0xa4**，是函数内 `__func__` 字面量池 ✓ |
| 同上 | `0x3eed3c` → `0xc03f6d3c` | `0xc03d975c` | **数据区的字符串指针表**（邻居全为 `0xc03d97xx` 指针），非函数边界 |
| `SI_ReadEDID` | `0x2e0e24` → `0xc02e8e24` | `0xc03d9fe8` | 落在 **`SI_ReadEDID`(0xc02e8d0c)+0x118`** ✓ |
| 同上 | `0x3eedc0` → `0xc03f6dc0` | `0xc03d9fe8` | 同一张数据指针表 |
| `HI_DRV_DISP_Init` | `0x2fc514` → `0xc0304514` | `0xc03dde6c` | 落在 **`HI_DRV_DISP_Init`(0xc0304464)+0xb0`** ✓ |

[推断] 每对引用的**第一个**是函数内 `__func__` / printk 的字面量池（正好印证 kallsyms 地址），
**第二个**是 `.rodata` 里的一张函数名指针表（`0xc03f6d3c` 附近连续 7 个 word 都是 `0xc03d9xxx` 指针）。
两者都**不是**函数入口；真正的入口来自 §1.1 的符号表。这比「从引用点回溯边界」更直接且可验证。

### 1.3 精确函数地址（节选，`d91d9104…` / kallsyms3）

| 函数 | VA | 函数 | VA |
|---|---|---|---|
| `DISP_Init` | `0xc0318078` | `DISP_HAL_Init` | `0xc02f02cc` |
| `DISP_HAL_InitVDPState` | `0xc02f0290` | `VDP_DRIVER_SetVirtualAddr` | `0xc02f2b1c` |
| `OPTM_GfxInit` | `0xc032e694` | `OPTM_VDP_DRIVER_Initial` | `0xc03254b8` |
| `HDMI_DRV_Init` | `0xc02dda78` | `HI_DRV_HDMI_Init` | `0xc02ddaa8` |
| `HI_DRV_HDMI_Open` | `0xc02dd670` | `DRV_HDMI_Init` | `0xc02e54e4` |
| `hdmi_ProcessCmd` | `0xc02dcd64` | `DRV_HDMI_Read_EDID` | `0xc02e35c8` |
| `SI_ReadEDID` | `0xc02e8d0c` | `SI_ReadSinkEDID` | `0xc02e8e28` |
| `SI_EDIDProcessing` | `0xc02ebec0` | `SI_BlockRead_MDDC` | `0xc02eba34` |
| `SI_TX_PHY_INIT` | `0xc02ecb70` | `SI_TX_PHY_WriteRegister` | `0xc02ec9e0` |
| `SI_HW_ResetCtrl` | `0xc02e943c` | `SI_HW_ResetPhy` | `0xc02e9484` |
| `DISP_ResetCRG` | `0xc02f77a4` | `Chip_Specific_DispSetPll` | `0xc02f1d54` |
| `HIFB_DRV_ModInit` | `0xc0338f08` | `register_framebuffer` | `0xc01d56c0` |

[观察] `HDMI_Display` 在 35,937 条符号中 **0 命中**；其字符串 VA `0xc077228c` 在
capstone 全文件 `ldr[pc]` 扫描范围内 **0 个字面量加载**。
→ 与 `docs/031 §2.1` 一致：内核里没有这个函数，等价功能由 `DRV_HDMI_Init` / `SI_Start_HDMITX` /
`SI_SetVideoPath` / `SI_EDIDProcessing` 分担。

---

## 2. 任务 1：`0xc084c870+0x258` 闭环与真实 MMIO 写入表

### 2.1 基址从物理常量到虚拟地址的完整闭环（capstone + radare2 逐条互验）

[观察] 七步闭环，全部来自 `d91d9104…`：

| 步 | 指令 VA | radare2 / capstone 反汇编 | 结果 |
|---|---|---|---|
| 1 | `0xc03180c0` | `ldr r0,[0xc031826c] ; =0xf8cc0000` → `bl 0xc02f02cc` | `DISP_Init` 把 VO **物理**基址传给 `DISP_HAL_Init` |
| 2 | `0xc02f0308` | `add r6,r6,0x5000000` → `str r6,[r4,0x258]`（r4=`0xc084c870`） | `0xf8cc0000+0x05000000` = **`0xfdcc0000`** 存入 `s_stDispCapability+0x258` |
| 3 | `0xc02f02a4` | `ldr r3,[0xc02f02c8] ; =0xc084c870` → `ldr r0,[r3,0x258]` → `bl 0xc02f2b1c` | **`DISP_HAL_InitVDPState` 就是 `+0x258` 的读取者**，把值交给 `VDP_DRIVER_SetVirtualAddr` |
| 4 | `0xc02f2b30` | `ldr r3,[0xc02f2b3c] ; =0xc084d030` → `str r0,[r3]` | 存入全局 **`pVdpReg`** → 之后 592 个 `VDP_RegWrite` 调用者都从这里取基址 |
| 5 | `0xc032e6c0` | `ldr r0,[0xc032e714] ; =0xfdcc0000` → `bl 0xc03254b8` | `OPTM_GfxInit` 硬编码同一 VO 虚基址；`OPTM_VDP_DRIVER_Initial` 存入 **`pOptmVdpReg`(0xc08564d0)** |
| 6 | `0xc02dda8c` | `ldr r2,[0xc02ddaa0] ; =0xfdce0000` → `ldr r3,=0xc084708c` → `str r2,[r3,0xc]` | `HDMI_DRV_Init` 把 **HDMI TX 虚基址 `0xfdce0000`** 写入 `0xc084708c+0xc` = **`g_VirHDMI_PHY_BASE_ADDR`(0xc0847098)** |
| 7 | `.data` | `0xc07d1730` 处 word = `0xfda22000` | 全局 **`g_pstRegCrg` 静态值 = CRG 虚基址 `0xfda22000`**；[未知] 本轮检索范围内未发现覆盖该全局本身的写入，但不排除存在 |

[观察] BSS 边界：`s_stDispCapability`(0xc084c870)、`pVdpReg`(0xc084d030)、
`g_VirHDMI_PHY_BASE_ADDR`(0xc0847098)、`pOptmVdpReg`(0xc08564d0) 与 `+0x258`(0xc084cac8)
**都在镜像 VA 上界 `0xC07E0AB8` 之外**，即 BSS，运行时才被写入；`g_pstRegCrg`(0xc07d1730)
在镜像内，故其静态值可直接读出。这解释了为何 `docs/034 §2.1` 的「指向该 VA 的指针数 0」
不等于「没人用」——用的是 `ldr[pc]` 字面量 + BSS 全局。

### 2.2 `+0x258` 读取点全表（回答 lead 的第 1 件事）

[观察] 全文件 `ldr/str [rN,#0x258]`（非 `[pc,#0x258]` 字面量）在显示代码区
`0xc02c0000–0xc0340000` 共 10 处，逐条定性：

| 指令 VA | 函数 | 指令 | 判定 |
|---|---|---|---|
| `0xc02f02a8` | `DISP_HAL_InitVDPState` | `ldr r0,[r3,#0x258]` → `bl VDP_DRIVER_SetVirtualAddr` | **[观察] 真正的基址取出点**（§2.1 步 3） |
| `0xc02f030c` | `DISP_HAL_Init` | `str r6,[r4,#0x258]` | **[观察] 写入点**（§2.1 步 2） |
| `0xc02f0b58` | `VideoLayer_CreateBlackFrame` | `ldr r3,[r4,#0x258]` → `str r3,[r4,#0x270]` / `add r3,r3,#0x4000` | [推断] 取出 VO 虚基址后写入**同一结构体的其它字段**（黑帧缓冲描述符），非 MMIO |
| `0xc0304d90` | `DISP_ProcRead` | `ldr r3,[r5,#0x258]` | [推断] `/proc` 打印用 |
| `0xc02d97e8` / `0xc02d9870` / `0xc02d9940` / `0xc02d995c` | `PQ_MNG_InitZme` / `PQ_MNG_DeInitZme` | `ldr/str [r4,#0x258]` | [观察] PQ 模块自有结构体字段，非 `s_stDispCapability` |
| `0xc02d3ca8` | `PQ_MNG_SetCSCPictureParam` | `ldreq r1,[r1,#0x258]` | [观察] 同上 |
| `0xc030f6b4` | `DispCastSetFrameInfo` | `str r3,[ip,#0x258]` | [观察] 同上 |

→ **[观察]** 只有 `DISP_HAL_InitVDPState` 把 `+0x258` 的 VO 虚基址送进 `pVdpReg`；
其余是 proc 打印或 PQ 结构体字段，**不能算 MMIO 写入**。

### 2.3 可验证的 MMIO 寄存器写入表（核心交付）

[观察] 统一写入口（`d91d9104…`，radare2 互验）：

```asm
VDP_RegWrite        0xc02f2b70  str r1,[r0]        ; 592 个调用者
OPTM_VDP_RegWrite   0xc0325524  str r1,[r0]        ; 131 个调用者
DRV_HDMI_WriteRegister 0xc02e649c  add r0,r0,#0x5000000 ; str r1,[r0]  ; 2 个调用者
```

[观察] **表 A：HDMI PHY 初始化写入（唯一有完整静态值的序列）**
来自 `SI_TX_PHY_INIT`(`0xc02ecb70`)，`SI_TX_PHY_WriteRegister`(`0xc02ec9e0`) 计算出
`r0 = 4*(reg + 0x3e338600) = 0xf8ce1800 + 4*reg`，`DRV_HDMI_WriteRegister` 再 `+0x05000000`
得到 VA `0xfdce1800 + 4*reg`（`docs/031 §2.3` 已列，radare2 `pd 10 @ 0xc02ecb84` 复核一致）：

| 序 | 指令 VA | 基址寄存器 | 偏移 | 物理地址 / VA | 写入值 | 来源 |
|---|---|---|---|---|---|---|
| 1 | `0xc02ecb8c` | r0（由 `SI_TX_PHY_WriteRegister` 计算） | `+0x000` | `0xf8ce1800` / `0xfdce1800` | 0 | `mov r0,#0; mov r1,r0` |
| 2 | `0xc02ecb98` | 同上 | `+0x008` | `0xf8ce1808` | 2 | `mov r0,#2; mov r1,r0` |
| 3 | `0xc02ecba4` | 同上 | `+0x00c` | `0xf8ce180c` | 2 | `mov r1,#2; mov r0,#3` |
| 4 | `0xc02ecbb0` | 同上 | `+0x010` | `0xf8ce1810` | 9 | `mov r1,#9; mov r0,#4` |
| 5 | `0xc02ecbbc` | 同上 | `+0x014` | `0xf8ce1814` | 4 | `mov r1,#4; mov r0,#5` |
| 6 | `0xc02ecbc8` | 同上 | `+0x018` | `0xf8ce1818` | 0 | `mov r1,#0; mov r0,#6` |
| 7 | `0xc02ecbd4` | 同上 | `+0x004` | `0xf8ce1804` | 1 | `mov r0,#1; mov r1,r0` |

[观察] **表 B：HDMI TX byte 寄存器写入**（发射器 3 组 bank，4 字节 stride）
`DRV_WriteByte_8BA`(`0xc02e6528`) radare2 互验：

```asm
0xc02e653c  cmp r1,0x72 ; beq 0xc02e6550
0xc02e6544  cmp r1,0x7a ; addne r2,r2,0x100   ; 0x7A → 第二 bank（+0x400 字节）
0xc02e6550  ldr r1,[0xc02e6560] ; =0xc0847098 (&g_VirHDMI_PHY_BASE_ADDR)
0xc02e6554  ldr r1,[r1]          ; r1 = 0xfdce0000
0xc02e6558  str r3,[r1,r2,lsl 2] ; 写：VA = 0xfdce0000 + 4*(reg|reg+0x100)
```

| 指令 VA | 基址寄存器 | 偏移 | 写入值 / 来源寄存器 |
|---|---|---|---|
| `0xc02e6558` | r1 = `*g_VirHDMI_PHY_BASE_ADDR` = `0xfdce0000` | `4*r2`（r2=寄存器索引；dev `0x7A` 时 `+0x400`） | r3（调用方参数） |
| `0xc02e66e4` | 同上（`DRV_WriteWord_8BA`） | `4*r2` | ip（调用方参数） |

[观察] `SI_BlockRead_MDDC`(`0xc02eba34`) 用这组写 `WriteByte_8BA(1,0x72,0xF3,9)`、
`0xF3=0xF/0xA`、`0xEC`，轮询 `0xF2` bit4 —— **EDID 走发射器自带 MDDC**（§4.1）。

[观察] **表 C：HDMI 复位 / CRG 写入（有编译期静态值）**
`g_pstRegCrg` = `0xfda22000`（§2.1 步 7）。radare2 逐条互验：

| 指令 VA | 函数 | 基址寄存器 | 偏移 | 物理/VA | 写入值 / 来源 |
|---|---|---|---|---|---|
| `0xc02e9478` | `SI_HW_ResetCtrl` | r3 = `*g_pstRegCrg` | `+0x10c` | `0xfda2210c` | r0 ∈ {`0x3f`(boot=0), `0x403f`(chip=2), `0x23f`(其它)}，由 `movw r2,0x403f` / `movw r3,0x23f` 定值 |
| `0xc02e94b0` | `SI_HW_ResetPhy` | r3 | `+0x110` | `0xfda22110` | r0 ∈ {1, `0x10`}（`moveq r0,1` / `movne r0,0x10`） |
| `0xc02e6e4c` | `SI_PoweDownHdmiDevice` | r1 | `+0x10c` | `0xfda2210c` | RMW：读值 → `bfc` bit0..5 → `orr #0x300` → `bfc` bit12/14 → 写回（**值随运行时状态变**） |
| `0xc02e6e60` | `SI_PoweDownHdmiDevice` | r2 | `+0x110` | `0xfda22110` | RMW：`bic r3,#0x11` → `orr r3,#0x10` → 写回 |

[观察] **表 D：CRG 时钟 / 复位写入（RMW，偏移确定、值不是常量）**
基址寄存器均为 `r3/r2/r0/r1 = *g_pstRegCrg` = `0xfda22000`（`ldr rX,=&g_pstRegCrg; ldr rX,[rX]`）。
radare2 对 `Chip_Specific_DispSetPll` / `DISP_ResetCRG` / `VDP_SetClkGateEn` 逐条互验：

| 指令 VA（示例） | 函数 | 偏移 | 写入值 / 来源寄存器 |
|---|---|---|---|
| `0xc02f1d78` | `Chip_Specific_DispSetPll` | `+0x28` | `ip = ldr[r0,#0x28]; bfi ip,r1,#0,#0x1f; str` → RMW |
| `0xc02f1d88` | `Chip_Specific_DispSetPll` | `+0x2c` | `r1 = ldr[r3,#0x2c]; bfi r1,r2,#0,#0x1b; str` → RMW |
| `0xc02f77f8` | `DISP_ResetCRG` | `+0xd8` | `r4`：读 `+0xd8` → `orr #0x7f` → `bfc/bfi` 位域 → `orr #0x4100000` → `orr #0x40000000` → 写回；再 `bfc #0x1e,#1` 后于 `0xc02f780c` **第二次写 `+0xd8`** |
| `0xc02f1d40` / `0xc02f2304` / `0xc02f1e50` | `Chip_Specific_DispSelectPll` / `DispSetChanClk` / `DISP_CloseClock` | `+0xd8` | RMW（读-改-写） |
| `0xc02f2db8` | `VDP_SetClkGateEn` | `+0x0`（`pVdpReg`） | `r2 = ldr[r3]; bfi r2,r0,#0x1f,#1; mov r0,r3; mov r1,r2; bl VDP_RegWrite` → RMW bit31 |
| `0xc02f2bc8` | `VDP_VID_SetLayerEnable` | `+0x800 + layer*0x800` | 地址 = `*pVdpReg + 0x800 + (layer<<9)*4`；值 = `ldr` 读回后 `bfi r2,r1,#0x1f,#1` → `bl VDP_RegWrite` |
| `0xc02e6e24`… | `SI_PoweDownHdmiDevice` | `+0x10c` / `+0x110` | 见表 C |

[观察] **表 E：其它已定位的 CRG 偏移**（由 §2 的 taint 全量扫描 +
`radare2` 抽样互验；均为 `*g_pstRegCrg` 基址）：

| 偏移 | 涉及函数（示例） | 类型 |
|---|---|---|
| `+0x94` | `TdeHalSetClock` / `tde_osr_isr` | RMW 写 |
| `+0x10c` / `+0x110` | `SI_HW_ResetCtrl` / `SI_HW_ResetPhy` / `SI_PoweDownHdmiDevice` / `SI_IsHDMIResetting` | 静态值 / RMW |
| `+0x11c` | `VDP_CloseClkResetModule` / `VDP_VDAC_ResetCRG` | RMW 写 |
| `+0xd8` | `DISP_ResetCRG` / `Chip_Specific_*` / `VDP_SelectClk` / `VDP_DISP_SetHdmiClk` / `PF_SetChnEnable` 等 | RMW 写（最密集） |

### 2.4 明确排除的假阳性（不把结构体写当 MMIO）

[观察] `docs/034 §3.3` 已排除 DISP 代码区 5183 条 `str rX,[fp,#-imm]` 栈帧局部变量。
本轮 taint 另排除：
- `PF_DACIsr` 对 `s_stDispCapability+0x120/0x128/0x130` 的 6 次 `str`、
  `PF_AcquireIntf2`/`PF_ReleaseIntf2` 对 `+0x48/0x4c` 的写 —— **BSS 结构体字段**，非 MMIO；
- `PQ_HAL_SRZmeRegCfg` 对 `pVdpReg_alt+0x30`、`hdmi_Resume` 对 `suspend_flag+0x10` —— 同类；
- `PQ_MNG_*` 的 `[rN,#0x258]`（§2.2）—— PQ 结构体字段；
- `VDP_DRIVER_Initial` 的 4 条 `str [rX,#0]` —— 写的是**全局指针本身**（`pVdpReg` 变量），不是寄存器。

[观察] 全量统计：taint 命中 1515 条「MMIO 相关」指令，其中 **43 条 `str`** 带被跟踪的
MMIO 基址标签；再按上表排重后，**真正落在 MMIO 窗口的写**集中在表 A–E。
[未知] `0xf9000000` 的 40 处命中多数在数据区（`initcall` 表、`kern_table`、`hid_usage_table`），
本次全文件 `ldr[pc]` 扫描**未检索到**把它当基址加载的代码，不能据命中数推断为 ioremap 基址。
[存疑] `0xf8ab0000` 的 3 处 `ldr[pc]` 加载（`0xc06fb880` / `0xc0769430` / `0xc07694cc`）
经 radare2 验证是**真实代码**（叶子函数，`ldr r3,[pc]; ldr r2,[r3,#0x84]; … bx lr`），
但它们与 `g_pstRegCrg=0xfda22000`、显示 MMIO 映射的关系**未建立**，本文不判为 CRG 基址。

---

## 3. 任务 2：HDMI 初始化函数体与调用链

[观察] 由 §1.3 符号表直接给出入口（不再靠字符串猜），`radare2` 复核关键 `bl`：

```
HDMI_DRV_ModInit (0xc02e117c)
 ├─ HDMI_ModeInit (0xc02e1058)   : hdmi_InitFmtArray / hdmi_Init_PixelClkArray / HI_DRV_DEV_Register
 ├─ HDMI_DRV_Init (0xc02dda78)   : 写 g_VirHDMI_PHY_BASE_ADDR=0xfdce0000 (§2.1 步6)
 │                                → bl DRV_HDMI_Register (0xc02ddf74) → HI_DRV_MODULE_Register
 └─ HI_LogOut
HI_DRV_HDMI_Init (0xc02ddaa8, 0x1C B) : 除 mcount 外仅 bl HDMI_DRV_Init（薄转发壳，无 MMIO）
HI_DRV_HDMI_Open (0xc02dd670)         : __memzero → hdmi_Open(0xc02dcacc, 0x28 B) → hdmi_ExtIoctl×3
hdmi_ExtIoctl (0xc02dd214)            : down_interruptible → hdmi_ProcessCmd → up
hdmi_ProcessCmd (0xc02dcd64, 0x4B0 B): ioctl 分发器；bl 目标含 DRV_HDMI_Init(0xc02e54e4)、
                                       DRV_HDMI_Open / Start / Stop / Read_EDID / SetFormat …
HI_DRV_HDMI_ProcHotPlug (0xc02dd9d4) → hdmi_MCE_ProcHotPlug (0xc02dd7c4)
```

[观察] `DRV_HDMI_Init`(`0xc02e54e4`) 是碰硬件的一段，其 `bl` 序列含
`SI_WriteBlockHDMITXP0`、`SI_HDMI_Setup_INBoot`、`DispFormatAdjust`、
`DRV_HDMI_Disp2UnfFmt`、`SI_Adjust_SwingCtrl`，分支 `0xc02e5660` 起连续三条：
`SI_HW_ResetHDMITX` → `SI_SW_ResetHDMITX` → `SI_TX_PHY_PowerDown`；随后
`SI_OpenHdmiDevice` / `SI_ReadBlockHDMITXP0` / `DRV_HDMI_SetDefaultAttr` /
`kthread_create_on_node(Hdmi_KThread_Timer)` / `SI_WriteDefaultConfigToEEPROM` /
`hdmi_SetAndroidState`。`SI_HW_ResetHDMITX` 内再调 `SI_TX_PHY_INIT`（表 A 的 7 次写入）。

[观察] `hdmi_ProcessCmd` 的 `bl` 目标逐条由符号表解析（见 `TMP/recovery-deep/disasm-hdmi-corrected.log`、
`disasm-final.log`），是「模块注册 + ioctl 分发」结构，**不是** `docs/023 §4.3` 的
`HI_UNF_HDMI_Open → HDMI_Display` 单一线性链。[推断] 二者是同一 HiSTB SDK 显示栈在
hiboot 与 Linux 内核的不同软件层实现，硬件步骤大体对应但调用结构不同。

---

## 4. 任务 3：EDID / 时钟 / 复位

### 4.1 EDID：发射器自带 MDDC，非 GPIO bit-bang I2C

[观察] `SI_EDIDProcessing`(`0xc02ebec0`) → `SI_HPD_Status` → `SI_ReadSinkEDID`(`0xc02e8e28`)
→ `SI_DDC_ResetTV` → `SI_ReadEDID`(`0xc02e8d0c`)×2 → `SI_ParseEDID` → `SI_AssignOutputState`
（失败 `SI_AssignDefaltOutputState`）。
[观察] `SI_ReadEDID` → `DRV_Get_IsUserEdid`（用户 EDID 覆写分支 `DRV_Get_UserEdid`）
→ `WriteByte_8BA` → `SI_BlockRead_MDDC`(`0xc02eba34`)；后者写
`WriteByte_8BA(1,0x72,0xF3,9)`、`SI_BlockWriteHDMITXP0(0xED,7,buf)`，
轮询 `ReadByte_8BA(1,0x72,0xF2)` bit4，再 `SI_BlockReadMDDCFifo`、
`ConvertMDDCStateIntoErrCode`，收尾写 `0xF3=0xF/0xA`、`0xEC`。
[观察] 字符串交叉引用：`hi_gpio` 的字面量加载只在 `GPIO_DRV_ModInit+0x38`
（通用 GPIO 驱动）；`MDDCState:I2C_LOW` 只在 `ConvertMDDCStateIntoErrCode+0x30`；
`/dev/hi_i2c` 字符串 1 处命中，但在全文件 `ldr[pc]` 扫描范围内**未检索到显示路径对它的引用**。
→ [观察] 在本次扫描范围内，EDID 路径是**发射器内部 MDDC 经 MMIO byte 寄存器**（表 B），
不是 GPIO bit-bang I2C。对应 `docs/032 §7` 第 5 条 **answered**。

### 4.2 时钟 / 复位：CRG 寄存器位操作，`clk_set_rate` 0 直接调用点

[观察] `clk_set_rate`(`0xc0018190`) 在全文件 raw ARM `bl` 解码（`0xEB……` 逐 word 算目标）
范围内 **0 个直接调用点**；`clk_get_rate` 的 4 个调用者全在 pl011 / sp804 / timer 通用路径；
`clk_enable` / `clk_disable` 调用者亦为 pl011 / amba / hinfc / pm_clk 等通用路径。
字符串 `clk_set_rate` 在镜像内 2 处命中（符号/日志文本），非显示调用。
[观察] 显示时钟由 `Chip_Specific_DISP_OpenClock`(`0xc02f1e5c`) → 读 `g_pstRegCrg+0xd8`
（`and r3,#0x40000003; cmp r3,3`）→ 条件调用 `DISP_ResetCRG`(`0xc02f77a4`)；
`Chip_Specific_DispSetPll`(`0xc02f1d54`) 写 CRG `+0x28`/`+0x2c`（表 D）；
另有 `VDP_DISP_SetHdmiClk` / `VDP_SelectClk` / `VDP_VDAC_SetClk` /
`VDP_CloseClkResetModule` / `MakePixClkParaInteger` / `hdmi_Init_PixelClkArray` /
`SI_SetMCLK` / `SI_SetIClk` / `DRV_Calculate_TMDSCLK` 等 vendor helper。
[观察] CRG 全局 `g_pstRegCrg` 静态值 `0xfda22000`（§2.1 步 7），
`+0xd8` 是最密集的时钟/复位寄存器，`+0x10c`/`+0x110` 是 HDMI 复位（表 C）。
→ [推断] 对主线而言，`clk_ignore_unused` 只是「别关掉」，**不足以**替代
CRG 的 `clocks`/`resets` DT 描述与主动 `clk_get/enable`（`docs/023 §5.3`、`docs/025 §1.3` 同向）。
[未知] 具体 clk 名与 CRG 各位含义未从本镜像解析（需 SDK `mach-hi3798mx/clock.c` / CRG 头或 DT 对照）。

---

## 5. 任务 4：`docs/032 §7` 七条回销 + SDK / `docs/029` 对照

### 5.1 七条清单逐条销账

| # | 问题 | 状态 | 结论（本文证据） |
|---|---|---|---|
| 1 | `HDMI_DRV_ModInit` 等真实调用链与寄存器顺序，对 SDK 序列 | **answered** | §3 调用链由 kallsyms 直接定位；§2.3 表 A 给出 7 次 PHY 写入「基址+偏移+值+顺序」；SDK 线性序列与内核非 1:1（§3） |
| 2 | `HI_DRV_DISP_Init`/`DISP_HAL_Init` 如何配 VO 图层、G0 还是 GP0 | **partially** | §2.1 基址闭环、`+0x258` 读取点实证；但 `G0_ADDR+0x494` 等偏移与 G0/GP0 归属未定死（§0 [未知]） |
| 3 | hifb 注册 fb0 的显存来源 / 格式 / stride / 分辨率 | **partially** | `HIFB_DRV_ModInit`→`register_framebuffer`、`DISP_OS_MMZ_Alloc`→`HI_DRV_MMZ_Alloc`、`hifb_buf_allocmem` 实证；格式/stride/分辨率未由本镜像定死（社区内核数值属另一对象，不互引） |
| 4 | 显示相关 clk 名、`clk_set_rate` 调用点、CRG 寄存器 | **partially** | §4.2：`clk_set_rate` 0 直接调用点；CRG 基址与 `+0xd8/+0x28/+0x2c/+0x10c/+0x110` 写入实证；clk 名/位含义 [未知] |
| 5 | `SI_ReadEDID` 走 DDC 还是 GPIO bit-bang I2C | **answered** | §4.1：发射器自带 MDDC，非 GPIO I2C |
| 6 | 是否有可继承的 Bootloader framebuffer | **unresolved** | 需真机验证；`docs/031 §7` 指出 U 盘刷机路径不做显示初始化 |
| 7 | `0xf8ce0000`/`0xf8cc0000`/`0xf9000000` 用途与 `docs/029` 对齐 | **partially** | 前两者用途实证（§2.1）；`0xf9000000` [未知]、`0x8ce0000` 关系 [存疑]/[推断]（§5.3） |

### 5.2 与 `docs/023 §4.2 / §4.3` SDK 序列对照

| SDK 项 | 本镜像实证 | 判定 |
|---|---|---|
| `CONFIG_VDP_REG_BASEADDR=0xf8cc0000` | `DISP_Init` 传参 + `DISP_HAL_Init` 加 `0x5000000` → `pVdpReg`（§2.1） | **[观察] 固件实证**，不再是 SDK 推测 |
| `G0_ADDR +0x494` / `G0_STRIDE +0x49c` / `G0_IRESO +0x4a0` | 未检索到把这三者当常量加载的代码；本镜像 `VDP_VID_SetLayerEnable` 用 `+0x800 + layer*0x800`（VID 层块），`OPTM_GfxSetLayerAddr` 引用 `g_stGfxGPDevice` | **[未知]** 仍只有 SDK 推导，本文未验证；两组不是同一寄存器块，不得互推 |
| `HI_UNF_HDMI_Init()` 空壳 | 内核 `HI_DRV_HDMI_Init` 0x1C B 转发壳（§3） | [观察] 方向一致，但为内核同名函数、非 hiboot 实现 |
| `HDMI_Display()` → EDID → AVI InfoFrame → `TX_PHY_*` → `TX_SetHDMIMode` | 内核无 `HDMI_Display` 符号；等价步骤分散在 `DRV_HDMI_Init`/`SI_Start_HDMITX`/`SI_EDIDProcessing`（§3、§4.1），`SI_TX_PHY_INIT` 实证 7 次写 | [推断] 同一 SDK 栈不同层，**非 1:1 线性序列** |
| `HI_DRV_HDMI_Init` 内建 `HDMI_Display` | 0x1C B 仅一次 `bl HDMI_DRV_Init` | [观察] 不符（该说法属 hiboot） |

### 5.3 与 `docs/029` 的张力：**标 [存疑]，不推翻**

[观察] 本 3.10 内核：`0xf8cc0000` 被 `DISP_Init` 用作 VO 物理基址（2 处字面量加载），
`0xf8ce0000` 在 `/proc/msp/hdmi0` help 函数（`0xc02e21a0`）被加载 1 次；
代码里硬编码的**虚拟**基址为 `0xfdcc0000`（VO）、`0xfdce0000`（HDMI TX）、
`0xf8ce1800+4*reg`（PHY，经 `+0x05000000` → `0xfdce1800`）；
`0x08ce0000` 在 `d91d9104…` 全文件字节范围内 **0 命中**（按规范只写「未检索到」）。
[推断] `0xf8ce0000 − 0x08ce0000 = 0xF0000000`，更可能是
「DT 相对地址 + 父总线 `ranges` 基址 = CPU 物理地址」的两种表示，
或 SDK 多 chip 条件编译常量，而非「mv100 用错地址」。
[存疑] 本文**不据此推翻 `docs/029`**：`docs/027 §6` 曾因同类
「0 命中 ⇒ 不存在」的推断被撤销；`SI_*`/`SiI_*` 前缀（符号表中 `SI_` 157 个、
`sii9134` 字面量 0 命中）恰恰补强 `docs/029` 的 SiI9134 bridge 结论。
[未知] 需读 `910-01` 的 `ranges` / `500-01` binding 原文确认映射关系；本文不下结论。

---

## 6. 证据边界、复现与合规

**边界（逐条声明）**

- 本文「写入表」是**静态反汇编 + 数据流 taint** 的结果，标注了对象 SHA-256、指令 VA、
  基址寄存器、偏移、写入值 / 来源寄存器、工具版本；**未观察到运行时执行**，
  「顺序」仅指函数体内指令 / `bl` 出现顺序。
- **[观察]** 表 A（7 次 PHY 写）与表 C 部分行（HDMI 复位）有**编译期静态值**；
  **[观察]** 表 B/D/E 多数是**读-改-写（RMW）**，最终值依赖运行时寄存器原值与参数，
  **本文不编造定值**，只给出可验证的位操作与来源寄存器。
- 「0 命中」一律指「在指定对象 / 指定扫描方式 / 指定范围内未检索到」：
  `HDMI_Display` 符号、`clk_set_rate` 直接 `bl`、`0x08ce0000`、`/dev/hi_i2c` 显示路径引用、
  `0xf9000000` 的 `ldr[pc]` 基址加载，均按此表述，不推出「不存在」。
- 未定死项标 `[未知]` / `unresolved`：G0/GP0 精确偏移、fb 格式/stride/分辨率、
  clk 名与 CRG 位含义、`0xf9000000` 用途、`0xf8ab0000` 三处叶子函数归属、
  bootloader framebuffer 可继承性。
- 跨对象不互引：社区 Ubuntu 的 fb 几何（`docs/023 §5.1`）、整机备份 `p05_baseparam`
  （`docs/027 §4.7`，另一对象）仅作背景；本文常量与写入全部来自 `d91d9104…`。

**复现产物（仓库内相对路径，均 gitignored）**

| 文件 | 用途 |
|---|---|
| `TMP/recovery-deep/kallsyms3.py` / `kallsyms-symbols.json` / `kallsyms3.log` | 压缩 kallsyms 重建（δ=−2，双 oracle 80/80），35,937 符号 |
| `TMP/recovery-deep/track035.py` / `track035-stage1.log` / `track035-stage1.json` | 全局字面量加载与 `[rN,#0x258]` 全量扫描 |
| `TMP/recovery-deep/track035b.py` / `track035-stage2.log` / `track035-stage2.json` | taint：全局 → 虚基址 → 偏移 → `str` / writer-call，1515 条 |
| `TMP/recovery-deep/track035c.py` / `track035-stage3.log` | 指针引用点解析、函数地址、`clk`/DDC 字符串 xref |
| `TMP/recovery-deep/disasm*.log` / `queries.log` / `mmio-xrefs.log` | 上一轮反汇编与交叉引用日志（本轮复用复核） |

**合规**：只读静态分析；不刷机、不改真机、不联网、不构建镜像、**不删除文件**、
不用 `rm` / `git clean`、不访问项目外目录；临时产物全在 `TMP/recovery-deep/`；
文档不含本机绝对路径 / 用户名 / 卷名，厂商构建机标识省略；
**只新建 `docs/035-recovery-hdmi-register-sequence.md` 一个文件**，未改动任何已跟踪文件，
未执行 `git add` / commit / push / checkout / 建分支 / 动索引，由主会话统一提交。
