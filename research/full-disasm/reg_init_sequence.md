# reg_init_sequence.md — 点亮 HDMI 的逐寄存器初始化序列（backport 可落地表）

> 服务 `docs/052` / `patches/vendor-display/PORTING.md` 阶段 1→2 硬依赖。目标：给 backport
> 驱动"逐字节来自原厂资产、不手写猜寄存器值"（docs/025 §2.2 铁律）。
> 机器可读版：`reg_init_sequence.tsv`（同目录）。证据可核对：`disasm_p11.txt`、
> `display_funcs_p11.txt` 按 VA 检索；`annotate.py` 可复现任一函数的 BL/literal/movw-movt 注解。
> 标注严格分 [观察]（指令/立即数/寄存器偏移/调用边）、[推断]（据观察推的功能/RMW 值）、
> [未知]（静态不可定、需真机）。**只读产物，写入仅 TMP，未改仓库/未刷机/未连设备/未触发CI/未装软件。**

---

## 0. 基址图与写入口（[观察]）

物理基址来自 SDK `drv_reg_proc.h` 与内核镜像里的全局数据字；虚拟地址 = 物理 + `0x05000000`
（内核静态 IO 映射，见 `DRV_HDMI_WriteRegister` 的 `add r0,r0,#0x5000000` 与 `DISP_HAL_Init`
的 `add r6,r6,#0x5000000`）。

| 窗口 | 物理基址 | 虚拟 | 来源（[观察]） |
|---|---|---|---|
| VO/VDP | `0xf8cc0000` | `0xfdcc0000` | SDK `CONFIG_VDP_REG_BASEADDR`；`DISP_Init@0x805DB2D4` `movw/movt 0xf8cc; bl DISP_HAL_Init`；`DISP_HAL_Init@0x805A95DC` `add r6,r0,#0x5000000; str r6,[r4,#0x258]` |
| HDMI TX SLV0 (dev 0x72) | `0xf8ce0000` | `0xfdce0000` | SDK `drv_reg_proc.h:24-27`；内核 `DRV_WriteByte_8BA` 读全局 `0x8112ff64` |
| HDMI TX SLV1 (dev 0x7a) | `0xf8ce0400` | `0xfdce0400` | `+0x100<<2=+0x400`；SDK `HDMI_TX_SLV1_ADDR_BASE` |
| HDMI TX CEC (dev 0xc0) | `0xf8ce0800` | `0xfdce0800` | `+0x200<<2=+0x800`；SDK `HDMI_TX_CEC_ADDR_BASE` |
| HDMI PHY | `0xf8ce1800` | `0xfdce1800` | SDK `phy.c:38-43`；内核 `SI_TX_PHY_WriteRegister` `movw #0x8600;movt #0x3e33` → `0x3e338600<<2=0xf8ce1800` |
| CRG 时钟/复位 | `0xf8a22000` | `0xfda22000` | 数据字 `@global 0x80FBA6A4 = 0xfda22000`；docs/035 `g_pstRegCrg=0xfda22000` |

**统一写入口（[观察]，逐条指令）**：
- `DRV_HDMI_WriteRegister @0x8059339C`：`add r4,r0,#0x5000000; str r5,[r4]`（r0=物理地址，r1=值）。
- `SI_TX_PHY_WriteRegister @0x805A50CC`：构造 `r0=4*(reg+0x3e338600)=0xf8ce1800+4*reg`，`r1=val`，`bl DRV_HDMI_WriteRegister`。
- `DRV_WriteByte_8BA @0x80592F64`：`base=*0x8112ff64`（HDMI TX 虚基址），按 dev 选 bank
  （0x72→+0，0x7a→+0x100<<2=+0x400，0xc0→+0x200<<2=+0x800），`str r3,[base+reg<<2]`。
  与 SDK `drv_hlviic.c:51-66 WriteByte_8BA` 的 `HDMI_REG_WRITE(SLVx_BASE+RegAddr*4, Data)` 逐字对应。
- `VDP_RegWrite @0x805AC640` / `OPTM_VDP_RegWrite @0x805F0730`：`str r1,[r0]`，地址由调用方
  `*pVdpReg + offset` 算出（docs/035 表 D：592 / 131 个调用者）。

> **[推断] 写入方式的含义**：所谓"I2C 8BA 字节写"在本芯片是**MMIO 寄存器窗口按 reg*4 寻址**，
> 不是真正的 I2C 时序；dev 0x72/0x7a/0xc0 是 3 个 bank 选择器。EDID 才是走发射器自带 MDDC
> （docs/035 §4.1）。backport 时 `WriteByte_8BA(bus,dev,reg,val)` 应实现为
> `writel(val, hdmi_tx_virt + bank_off(dev) + reg*4)`。

---

## 1. 可落地的"确定性写入序列"（静态常量，[观察]）

### 序列 A：HDMI PHY 初始化 —— `SI_TX_PHY_INIT @0x805A5438`（7 次写，顺序即源码顺序）
内核每次 `mov r0,#reg; mov r1,#val; bl SI_TX_PHY_WriteRegister@0x805A50CC`，落在 `0xf8ce1800+4*reg`。
**独立 oracle**：docs/035（mainline-porting 分支，recovery 3.10 内核，radare2+capstone）表 A 给出
**完全相同的 7 组 (reg,val)**——两份不同内核、两套工具链互证。

| # | 物理地址 | reg | 写入值 | 指令 VA | SDK 语义名(phy.h) | 交叉 |
|---|---|---|---|---|---|---|
| 1 | `0xf8ce1800` | 0 | `0x00` | `0x805A5454` | OE | docs/035 表A row1 |
| 2 | `0xf8ce1808` | 2 | `0x02` | `0x805A5460` | AUD | row2 |
| 3 | `0xf8ce180c` | 3 | `0x02` | `0x805A546C` | PLL1 | row3 |
| 4 | `0xf8ce1810` | 4 | `0x09` | `0x805A5478` | PLL2 | row4 |
| 5 | `0xf8ce1814` | 5 | `0x04` | `0x805A5484` | DRV | row5 |
| 6 | `0xf8ce1818` | 6 | `0x00` | `0x805A5490` | CLK | row6 |
| 7 | `0xf8ce1804` | 1 | `0x01` | `0x805A549C` | PWD（power-up 放最后） | row7 |

> **[观察·重要偏差] 第 5 项的值**：真实内核二进制（本 p11 正常开机 3.10 **与** docs/035 recovery 3.10）
> 都写 `0x04`；但 SDK `source/boot/product/driver/hdmi/hdmi_1_4/phy.c` 的 mv100 分支
> （`:291-313`，`TX_PHY_WriteRegister(PHY_DRV_ADDR,0x01)`）写 `0x01`。这是**源码快照与刷入二进制
> 的版本漂移**。按"逐字节来自原厂资产、不手写猜"与"以反汇编为准"原则，**backport 应采用二进制值
> `0x04`**（两份真内核一致），并在注释标明 SDK 源码为 0x01 供溯源。其余 6 项源码/二进制一致。
> SDK mv100 分支顺序为 OE/AUD/PLL1/PLL2/DRV/CLK/PWD，与内核二进制顺序一致（PHY_PWD 最后）。

### 序列 B：HDMI HW 复位 / CRG（`SI_HW_ResetHDMITX @0x8059BD40`，顺序即源码顺序）
CRG 基址 `0xf8a22000`（虚 `0xfda22000`）。`r4=0x80fba6a4` 存 CRG 虚基址。

| # | 物理地址 | 值 | 指令 VA | 说明（[观察]） |
|---|---|---|---|---|
| 1 | `0xf8a2210c` (+0x10c) | `0x23f` | `0x8059BD78` | `movw r2,#0x23f; str r2,[r1,#0x10c]` 复位断言 |
| 2 | `0xf8a22110` (+0x110) | `0x10` | `0x8059BD84` | `mov ip,#0x10; str` PHY 复位 |
| 3 | — | DelayMS(1) | `0x8059BD88` | `bl DelayMS` |
| 4 | `0xf8a22110` (+0x110) | `0x01` | `0x8059BD98` | `r5=1; str` 解 PHY 复位 |
| 5 | — | DelayMS(1) | `0x8059BD9C` | `bl DelayMS` |
| 6 | — | `bl SI_TX_PHY_INIT` | `0x8059BDA0` | 触发序列 A 的 7 次 PHY 写 |
| 7 | — | DelayMS(1) | `0x8059BDA8` | `bl DelayMS` |
| 8 | `0xf8a2210c` (+0x10c) | `0x3f` | `0x8059BDB8` | `mov r2,#0x3f; str` 解复位 |
| 9 | — | DelayMS(10) | `0x8059BDBC` | `mov r0,#0xa; bl DelayMS` |
| 10 | `0xf8ce01ec`（SLV0 reg 0x7b） | `0x02` | `0x8059BDD0` | `WriteByte_8BA(1,0x72,0x7b,2)` |
| 11 | `0xf8ce03d8`（SLV0 reg 0xf6） | `DRV_Get_DDCSpeed()` | `0x8059BDE8` | **[推断]** 值来自运行时 `DRV_Get_DDCSpeed`，非静态常量 |

补充静态可定分支（[观察] 指令，[推断] 值选择）：
- `SI_HW_ResetCtrl @0x8059AD9C`：`str r0,[r1,#0x10c]`，`r0 ∈ {0x3f(boot=0), 0x403f(chip=2), 0x23f(其它)}`
  （`moveq #0x3f / movw #0x403f / movw #0x23f`）——docs/035 表 C 同。
- `SI_HW_ResetPhy @0x8059ADE4`：`str r0,[r3,#0x110]`，`r0 ∈ {1, 0x10}`（`moveq #1 / movne #0x10`）。

### 序列 C：HDMI TX 唤醒/时钟/模式（8BA 字节写，物理 `0xf8ce0000`/`0xf8ce0400` + reg*4）
| 物理地址 | 值 | 来源函数@VA | 标注 |
|---|---|---|---|
| `0xf8ce0020`(SLV0 reg 8) | `read\|1` (RMW) | `SI_WakeUpHDMITX@0x8059B2EC` | [推断] 运行时值；SDK `HDMI_Display:377 WakeUpHDMITX()` |
| `0xf8ce01ec`(SLV0 reg 0x7b) | `0x02` | `SI_WakeUpHDMITX@0x8059B300` | [观察] `WriteByte_8BA(1,0x72,0x7b,2)` |
| `0xf8ce0120`(SLV0 reg 0x48) | `(read&0xfc)\|IClk` | `SI_SetIClk@0x8059B17C` | [推断] RMW；SDK `HDMI_Display:375 SetIClk(0)` → IClk=0 |
| `0xf8ce04bc`(SLV1 reg 0x2f) | `read\|1`(HDMI)/`&0xfe`(DVI) | `SI_TX_SetHDMIMode@0x8059B0FC` | [推断] 取决于 `hdmi_dvi_mode`；SDK `HDMI_Display:805 TX_SetHDMIMode()` |
| SLV1 `ACR_CTRL_ADDR` | `0x04` | SDK `hdmi.c:421 WriteByteHDMITXP1(ACR_CTRL_ADDR,0x04)` | [观察] 来自 SDK 原厂资产（boot/hiboot 源码），对应内核 `hdmi_Open` 路径 |
| SLV0 `0xf8ce04cc`(reg 0xf3) | `0x09` | `SI_BlockRead_MDDC`（docs/035） | [观察] EDID DDC 触发 `WriteByte_8BA(1,0x72,0xF3,9)`；EDID 运行时读 `0xF2` bit4 轮询 |

> **[观察·SDK 条件编译陷阱]**：SDK `hdmi.c:358` 的 `HW_ResetHDMITX()/SW_ResetHDMITX()` 被
> `#if !(defined(CHIP_TYPE_hi3798mv100)||...)` 包住 → **mv100 不执行**。`hdmi.c:392-418` 里
> 那组绝对地址 `HDMI_REG_WRITE(0xf8cd0158,0x333333)` 等在 `#if 0` 内（**死代码**）。
> `hdmi.c:409-417` 的 `0xf8cd0158/0xf8cd015c/0xf8ce040c/0xf8ce0410/0xf8ce0414/0xf8ce0450`
> **不是活动初始化序列**，backport 不应照抄这段。活动的 mv100 路径是 `UpdateTX_656 → SetIClk(0)
> → WakeUpHDMITX → (CEC) → WriteByteHDMITXP1(ACR_CTRL,0x04) → SetVideoPath → TX_SetHDMIMode
> → AVI InfoFrame`。

### 序列 D：DISP / CRG 时钟与 G0 图层配置（[观察] 偏移，[推断] 值多为 RMW）
| 物理地址 | 操作 | 来源函数@VA | 标注 |
|---|---|---|---|
| `0xf8a220d8`(+0xd8) | `read &0x40000003`；`!=3` 则 `DISP_ResetCRG` | `Chip_Specific_DISP_OpenClock@0x805AB7DC` | [推断] RMW；`DISP_Init→DISP_HAL_Init→OpenClock` |
| `0xf8a22028`(+0x28) | `bfi(r1,#0,#0x1f)` | `Chip_Specific_DispSetPll@0x805AB6DC` | [推断] PLL 参数运行时（docs/035 表 D） |
| `0xf8a2202c`(+0x2c) | `bfi(r2,#0,#0x1b)` | `Chip_Specific_DispSetPll@0x805AB6EC` | [推断] PLL 参数运行时 |
| `0xf8cc6010`(+0x6010) | 写显存物理地址 | `VDP_GFX_SetLayerAddr@0x805B6ACC` | [观察] `add #0x6000; add #0x10; str`（FINDINGS §D 真值）；值 = fb_base（来自 pdm_tag/MMZ，运行时） |
| `0xf8cc601c`(+0x601c) | 写 stride 低16 | `VDP_GFX_SetLayerAddr@0x805B6AEC` | [观察] `add #0x1c; strh`；1080p → 7680 |
| `0xf8cc6020`(+0x6020) | 写 IRESO (iw/ih) | `VDP_GFX_SetLayerAddr` 关联 | [推断] 1920/1080 |
| `0xf8cc6000`(+0x6000) | G0_CTRL layer enable/format | `OPTM_GfxOpenLayer`/`SetLayerAddrEX@0x805F4178` | [推断] RMW |
| `layer*0x800` | `addr(layerN)=0xf8cc0000+0x6010+(N<<11)` | `VDP_GFX_SetLayerAddr` 等 | [观察] `CONFIG_HIFB_GFX_OFFSET=0x800`；`str [..,r0,lsl#11]` |

---

## 2. 给 backport 驱动的最小可落地清单（docs/052 / PORTING.md）

1. **ioremap 窗口**（[观察]，SDK `CONFIG_VDP_SIZE=0xfff0`）：
   - `vo = ioremap(0xf8cc0000, 0xfff0)`（G0 至少 ≥0x7000，建议 0xfff0）。
   - `hdmi_tx = ioremap(0xf8ce0000, 0x2000)`（含 SLV0/SLV1/CEC/PHY 4 个窗口到 0xf8ce1818）。
   - `crg = ioremap(0xf8a22000, 0x200)`（用到 +0xd8/+0x28/+0x2c/+0x10c/+0x110/+0x11c）。
   - 内核用 `phys+0x05000000` 静态映射；主线改 `ioremap` 后按返回值 + 偏移 `writel/readl`。
2. **可硬编码的静态序列**（逐字节来自二进制，最放心）：序列 A 的 7 次 PHY 写（含 reg5=0x04）、
   序列 B 的 CRG 复位 5 次写 + 3 个 DelayMS、序列 C 的 `reg0x7b=0x02`、`ACR_CTRL=0x04`。
   全部有确定值 + 确定顺序 + 指令 VA，可直接写成 `writel` 表。
3. **必须运行时算、不能写死的**（[推断]/[未知]，docs/035 铁律）：
   - 所有 RMW（CRG +0xd8/+0x28/+0x2c、HDMI TX 唤醒/时钟/模式 reg、G0_CTRL）——先 readl 再改位再 writel。
   - `fb_base`（G0_ADDR 值）= `pdm_tag` 里 `HIFB_DispBuf_HD` 的物理地址或 MMZ 运行时分配；
     **不要抄 0x3C55C000**（那是社区 4.4 内核自有 fb0）。
   - EDID / HPD / 显示时序（1080p60 等）由 sink 运行时读，`g_stDispTiming` 仅 fallback。
   - `DRV_Get_DDCSpeed()` 返回值、`hdmi_dvi_mode`、deep-color 参数。
4. **顺序**（[观察] 来自 `MCE_ModuleInit@0x8089B608/0x8089B614` 调用边 + 各函数体）：
   `HI_DRV_HDMI_Init → HI_DRV_DISP_Init(DISP_Init→DISP_HAL_Init→OpenClock/SetPll) →
   HI_DRV_HDMI_Open → SI_HW_ResetHDMITX(含序列A) → WakeUp/SetIClk → G0 图层配置 →
   TX_SetHDMIMode/AVI InfoFrame → 输出`。**注意**：正常开机 MCE 模块把 HDMI 与 DISP 一起拉起，
   具体 initcall 间顺序与 EDID 到达时刻是运行时事件（[未知]），静态只能给函数内顺序。

---

## 3. 诚实边界（不假装已定）

- **[未知] "驱动该读哪个窗口"的真机确认仍未做**：本表物理基址来自 SDK `drv_reg_proc.h`
  与内核全局数据字（静态 [观察] 强证据），但**全网 docs/TMP 没有一次在 `0xf8ce0000`/`0xf8cc6010`
  上的真机 MMIO 读值**。社区内核 `/dev/mem` 对外设区 Bus error（fb-report-1 §7）。
  真机确认动作见 UNKNOWNS.md 优先级 3。
- **[推断] RMW 一律不伪造成定值**：docs/035 §2.3 明确"绝大多数写入值是运行时读改写，不是静态常量；
  只有 HDMI PHY 7 次写与 HDMI 复位 CRG 少数写有编译期静态值"。本表已据此把 RMW 标 [推断]。
- **[观察] 源码/二进制漂移**：序列 A 第 5 项 `0x04`(二进制/双内核) vs `0x01`(SDK 源码)。
  "逐字节来自原厂资产"应取**刷入的二进制**（本表序列 A），SDK 源码仅作语义名/顺序溯源。
- **[未知] 函数存在性差异**：team-lead 点名的 `hdmi_Disp2EncFmt`、`TX_PHY_WriteRegister`、
  `HDMI_Display`、`TX_SetHDMIMode`、`TX_PHY_HighBandwidth`、`TX_PHY_SwingCtrl` 是 **SDK/hiboot
  (`source/boot/product/driver/hdmi/hdmi_1_4/`) 的函数名**；在 p11 内核 kallsyms 里对应
  `SI_TX_PHY_WriteRegister`、`SI_TX_SetHDMIMode`、`SI_TX_PHY_HighBandwidth`、`SI_Adjust_SwingCtrl`
  等（前缀 `SI_`）。`hdmi_Disp2EncFmt` 是 SDK `hdmi.c:901` 的**格式→VIC 枚举映射表**（不是寄存器写），
  1080P_60/720P_50 等 case 已逐条在 SDK 源码，backport 按 `hdmi.c:901-1049` 照抄映射即可。
- **[未知] 完整 HDMI TX 逐字节序列**：内核 `HI_DRV_HDMI_Open`/`hdmi_Open`/`hdmi_Display` 路径里还有大量
  运行时/EDID 条件分支的 8BA 字节写（InfoFrame、音频、HDCP、色彩空间），本轮只把**确定性的点亮相关
  静态写**与**写入机制/基址/bank 规则**落地。完整逐字节上屏表需在真机 EDID+sink 条件下动态采集或
  逐分支把 SDK `hdmi.c:192-822` 全量对齐（标注为后续静态工作，未假装完成）。
- **[未知] 内核是否启动**：仍为 UNKNOWNS.md 优先级 0；给没启动的内核 backport 显示驱动无意义。
  需绿带/pstore/IP 先确认（docs/024 §6.1 / docs/026）。
