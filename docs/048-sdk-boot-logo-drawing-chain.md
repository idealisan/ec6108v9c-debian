# 048 — 引导程序「如何绘制图像」的 SDK 源码级链路（含显存地址推导与 mw.l 判定）

> 2026-11-08。承接 `docs/045`（对**二进制** `bac0be9f…` 的静态负结果：这份 p1 里显示实现是 dead 符号池、0 引用）与用户连问的
> 「还是说，其实到现在都没有搞清楚，刷机程序和引导程序究竟是如何绘制图像的，这是最基本的要求」
> 「一定要用阶段图这种方法吗？就不能像一个普通的正常的程序那样去填充颜色吗？」。
>
> 本文用**另一条独立证据链**——本机 `TMP/sdk-src/` 里的 HiSilicon SDK 源码（boot/fastboot + product/driver
> graphic/gfx/pdm/hdmi）——正面回答「绘制机制是什么、显存地址怎么来、填色到底可不可行」。
> **两条证据不矛盾**：`docs/045` 说的是「显示实现的机器码不在我们备份的那份 `3.3.0-00786` p1 里」，
> 本文说的是「SDK 源码给出的绘制算法长这样」；源码对应的正是 `docs/045 §1.6` 推断的「含 `higo/adp_gfx.c`
> 的那个构建」（histb 板子页 `3.3.0-00709` boot log 运行时打印该文件名）。二者对象不同。
>
> 方法：`docs/033 §2` REA 三分法 `[观察]/[推断]/[未知]`；路径一律仓库内相对路径 `TMP/sdk-src/…`（不入库，
> gitignore）；不编造寄存器/显存地址；对象为源码文本，行号随源码固定。
> 相关：`docs/022`（HDMI 驱动设计）、`docs/023`（recovery 显示 / SDK 源码）、`docs/031`/`037`（社区 hiboot 负结果）、
> `docs/036 §4.2`（刷机分支不初始化显示）、`docs/039`（社区两张 logo 机制）、`docs/040`（真机写 `/dev/fb0` 实证）、
> `docs/041`（reserve-mem 实测）、`docs/043`（6.3 simplefb/VO 地址）、`docs/045`（本轮二进制侧坐实）、`docs/046`（进度方案）。

---

## 0. 结论先行 —— 直接回答「怎么画的」「能不能只填颜色」

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| 1 | **引导程序把 p7 那张 JPEG 变成屏幕像素的完整链路？** | **五环，全部在源码里可见**（§1）：① PDM 从 logo 分区读 `LOGO_TABLE` 里的 JPEG 数据；② `HI_GFX_DecImg` 解码成 `DecSurface`；③ `HI_GFX_RESERVE_Malloc` 从 **reserve 区（DDR 顶端向下）** 分配一段连续物理显存 `u32ScreenAddr`；④ `OPTM_GfxSetLayerAddr` → `OPTM_VDP_GFX_SetLayerAddrEX` 把该物理地址写进 **VO 的 `G0_ADDR` 寄存器**，并配 stride/format/rect；⑤ `HI_UNF_HDMI_Open → HDMI_Display` 复位/上电 HDMI PHY 后，VO 硬件**持续 DMA 扫描** `G0_ADDR` 指向的显存，经 HDMI 输出。 | [观察] |
| 2 | **「像普通程序那样填充颜色」在硬件层面成不成立？** | **成立，而且正是显示本质**。VO 一旦被配好并开启，屏幕像素就是 `G0_ADDR` 那段显存内容的实时映射；对显存 `mw.l <addr> <ARGB8888> <count>` 写纯色，屏幕就变色——**根本不需要图片资源**（`docs/040` 真机写 `/dev/fb0` 出彩色条纹/文字即是此原理）。用户直觉正确。 | [观察] + [推断] |
| 3 | **那为什么刷机阶段不直接 `mw.l` 填色做进度？** | **前提①仍未满足，前提②已被推翻**（本轮更新，详见 `docs/049`）：① 刷机分支（`bootcmd`）执行时 **VO/HDMI 是否已被初始化并正在扫描显存/输出信号**——`docs/036 §4.2` 实证「不做显示初始化」、板子页 boot log 刷机分支全程无 GFX 行、用户实测「社区刷机最初也是两三分钟黑屏、不显示进度」→ 若 VO/HDMI 没活，往显存写也不会亮；② 「`G0_ADDR` 地址静态不可知」**已被推翻**：多份独立 `mem=1G` 日志的 `Reserve Memory` 表完全一致（`Start 0x3FFFE000`、4 MiB 块 `0x3FBFD000`、3 MiB 块 `0x3F8FC000`），且本文 §2 用 `reserve_mem.c` 源码算法逐行复现吻合 → 地址**固定可推导**。 | [观察] + [推断] |
| 4 | **显存地址能否由我们推算？** | **能，且有源码级验证**（本轮更新）。`reserve_mem_init()` 从 `mem=` 解析 DDR 顶端（`mem=1G` → `0x3FFFE000`），`reserve_mem_alloc` 从顶端向下按 `size+ALLOC_ALIGN` 递减；本文 §2 用该算法复现日志三行地址**全部吻合**（REA 独立 oracle）。**仍 [未知]**：这几块里哪一块是 VO `G0_ADDR` 帧缓冲、刷机分支是否走到 `HI_GFX_ShowLogo`、跨构建/跨次上电是否恒定。不编造哪一块是帧缓冲。 | [观察] + [推断] + [未知] |
| 5 | **一句话给用户**：最简呈现方式与还差的事实？ | 最简＝`mw.l` 对活跃显存填 32-bit 纯色（无需图片）；**绘制机制已坐实、地址已可推导**。还差的**唯一决定性事实**＝「短接刷机 `bootcmd` 执行期间，VO/HDMI 是否已被点亮并扫描显存」——公开资料无法区分「黑屏＝无信号」还是「扫描黑帧」，`docs/049 §4` 给了一个**零风险、不写 eMMC 的纯诊断 `bootargs.bin`**，一次上电即可定案。 | [推断] |
| 6 | **用户本轮实测澄清** | 社区刷机**也**是「最开始两三分钟黑屏、并不能显示进度」；先前提供的两张图都不是刷机执行期间的画面，而是刷完/`reset` 后下次正常开机画的 p5（`docs/039`）。→ 复用社区现有显示机制做刷机进度这条路**不成立**；刷机阶段显示必须自己点亮 VO/HDMI，或走「下次开机看阶段图」。 | [观察] |

---

## 1. 绘制链路全图（源码级，每环给文件:行）

```
 p7 logo 分区 / DDR 源
   │  LOGO_TABLE 容器里的 JPEG
   ▼
 PDM_ReadLogoData / HI_DRV_PDM_GetLogoData        source/boot/product/driver/pdm/drv_pdm.c
   │  HI_DRV_PDM_GetLogoData(Len, &pLogoDataAddr)
   ▼
 HI_GFX_ShowLogo(pInputBaseLogoInfo)              .../graphic/gfx/hi_gfx_show.c:73
   ├─ HI_GFX_DecImg(LogoDataBuf, LogoDataLen,&DecSurface)   :84   解码 JPEG
   └─ HI_BOOT_GFX_DisplayWithLayerOrVo(..., DecSurface)      :92
        ▼
 BOOT_GFX_DisplayLogoWithLayer(..., HI_GFX_LAYER_HD_0, ...)  .../graphic/gfx/hi_gfx_layer.c:251
   ├─ GFX_CreateLayer(...) → GfxOpenLayer(...)               :382
   │     ├─ u32Stride = (w*4 + 0xf) & ~0xf   (ARGB8888)      :617
   │     ├─ u32BufferSize = stride*h[*bufnum]                :631/633
   │     ├─ pPhyAddr[0] = HI_GFX_RESERVE_Malloc(size,"HIFB_DispBuf_HD")  :637
   │     │      → BOOT_GFX_RESERVE_Alloc → HI_DRV_PDM_AllocReserveMem → reserve_mem_alloc()
   │     ├─ u32ScreenAddr = (HI_U32)pPhyAddr[0]              :656
   │     ├─ OPTM_GfxInit / OpenLayer / SetLayerDataFmt        :425-427
   │     ├─ OPTM_GfxSetLayerStride(7680)                      :428
   │     ├─ OPTM_GfxSetLayerAddr(s32DataId, u32ScreenAddr)    :429  ★写显存物理地址
   │     │      → OPTM_GfxSetLayerAddr → OPTM_VDP_GFX_SetLayerAddrEX   drv_hifb_adp.c:2491/2499
   │     │      → G0_ADDR.u32 = u32LAddr; RegWrite(...G0_ADDR...)      drv_hifb_hal.c:582/583
   │     └─ SetLayerRect / SetGpRect / SetDispFMTSize / GpInitFromDisp  :431-434
   ├─ HI_BOOT_GFX2D_Init / HI_GFX_FillRect / HI_GFX_Blit     :280/287/296
   └─ GFX_RefreshLayer(...) → 触发 REGUP，VO 开始扫描         :303 / :868
 HDMI 侧（并行/先后，§1.5）
   HI_UNF_HDMI_Init()     HW_Reset + SW_Reset + TX_PHY_PowerDown(TRUE)  .../hdmi/hdmi_1_4/hdmi.c:827
   HI_UNF_HDMI_Open(fmt)  RSEN 检测 → TX_PHY_PowerDown(FALSE) → HDMI_Display  :840/:860/:863
   HDMI_Display(fmt,...)  AVI InfoFrame / 色彩空间 / PHY / 时序              :192
   HI_UNF_HDMI_Start()                                                       :875
```

### 1.1 数据从哪来（[观察]）
`source/boot/product/driver/pdm/drv_pdm.c`：
- `PDM_ReadLogoData`：DDR 源时 `*pAddr = g_stMemInfo.u32LogoAddr + MCE_DEF_LOGOPARAM_SIZE`；
  flash 源时 `HI_Flash_OpenByName(PDM_LOGO_DEF_NAME)` + `HI_Flash_Read` 读进 `malloc` 缓冲。
- `HI_DRV_PDM_GetLogoData`：按 `g_bUseBackupLogo` 选 `logo` / `logobak`。
- `HI_DRV_PDM_AllocReserveMem`（`:2299`）：`*pu32PhyAddr = (HI_U32)reserve_mem_alloc(u32Len,&AlignSize);`

### 1.2 解码与图层（[观察]）
`source/boot/product/driver/graphic/gfx/hi_gfx_show.c:73` `HI_GFX_ShowLogo` 先 `HI_GFX_DecImg` 解码，再
`HI_BOOT_GFX_DisplayWithLayerOrVo`；后者（`hi_gfx_layer.c:139`）固定 `LayerId = HI_GFX_LAYER_HD_0`，调
`BOOT_GFX_DisplayLogoWithLayer`（`:251`）：`GFX_CreateLayer` → `HI_BOOT_GFX2D_Init` → `HI_GFX_FillRect`（默认底色
`0xffaabbcc`）→ `HI_GFX_Blit(DecSurface→LayerSurface)`（缩放 blit）→ `GFX_RefreshLayer`。

### 1.3 显存分配（[观察]，关键）
`source/boot/product/driver/graphic/gfx/hi_gfx_layer.c:612-656`：
- `u32Stride[0] = (w*4 + 0xf) & 0xfffffff0`（`HI_GFX_PF_8888` → 1920×4 = 7680）；
- `CONFIG_GFX_DOUBLE_BUFFER_SUPPORT` 时 `× CONFIG_GFX_LAYER_BUF_NUM`（`hi_gfx_show.h:35` = 2），
  但 `source/boot/product/driver/graphic/Makefile:43` 把该宏**注释掉** → boot 阶段默认单缓冲
  `u32BufferSize = 7680×1080 = 0x7E9000`（与 `docs/040` 内核 hifb 双缓冲 `smem_len=0xFD2000` 区分开）；
- `pPhyAddr[0] = HI_GFX_RESERVE_Malloc(u32BufferSize, "HIFB_DispBuf_HD")`（`:637`）；
- `u32ScreenAddr = (HI_U32)pPhyAddr[0]`（`:656`）——**这就是最终写进 VO 的物理地址**。

`source/boot/product/driver/graphic/gfx/hi_gfx_mem.c:47` `BOOT_GFX_RESERVE_Alloc` →
`HI_DRV_PDM_AllocReserveMem(name, size + CONFIG_GFX_RESERVE_SIZE(10), &phy)` → `reserve_mem_alloc`。

### 1.4 写 VO 寄存器（[观察]，核心动作）
`source/msp/drv/hifb/adp/src/drv_hifb_adp.c:2491` `OPTM_GfxSetLayerAddr` →
`OPTM_VDP_GFX_SetLayerAddrEX(g_pstGfxDevice[enLayerId]->enGfxHalId, u32Addr)`（`:2499`）；
`source/msp/drv/hifb/adp/hal_v1_0/drv_hifb_hal.c:565` 实现里：
```c
G0_ADDR.u32 = u32LAddr;                                             // :582
OPTM_VDP_RegWrite((HI_U32*)(&(pOptmVdpReg->G0_ADDR.u32)
        + u32Data * CONFIG_HIFB_GFX_OFFSET), G0_ADDR.u32);          // :583
```
`pOptmVdpReg` 由 `OPTM_VDP_DRIVER_Initial(virAddr)`（`:105`）传入的 `virAddr` 设定，即 VO 寄存器区
ioremap（对外基址见 `docs/022` 的 `VO_REG_BASE=0xf8cc0000` 一带，本文不重新断言具体数值）。
**结论**：显示 = 把解码后像素写进 `u32ScreenAddr` 那段 DDR，再把该**物理地址**写进 `G0_ADDR`，
配好 `G0_STRIDE`/format/rect 后 VO 硬件持续扫描。此后显存内容即屏幕内容。

### 1.5 HDMI 输出（[观察]）
`source/boot/product/driver/hdmi/hdmi_1_4/hdmi.c`：
`HI_UNF_HDMI_Init`（`:827`）→ `HW_ResetHDMITX` + `SW_ResetHDMITX` + `TX_PHY_PowerDown(HI_TRUE)`；
`HI_UNF_HDMI_Open`（`:840`）→ 查 `TX_RSEN_Status()`（接收器在位）→ `TX_PHY_PowerDown(HI_FALSE)`（`:860`）
→ `HDMI_Display(enFormat, …)`（`:863/:867`，配 AVI InfoFrame / 色彩空间 / PHY / 输出时序，函数体 `:192`）；
`HI_UNF_HDMI_Start`（`:875`）。
`docs/035` 的 recovery 内核 MMIO 序列（HDMI PHY 7 写 `0xF8CE1800+4*reg`、CRG/VO 时钟）与此源码同族。

---

## 2. 显存物理地址推导（reserve_mem_alloc 确定性）

[观察] `source/boot/fastboot/lib/reserve_mem.c`：
```c
// reserve_mem_init()  :163
parse_mem_args(&start, &size);                 // 从 mem= 解析，失败用 bi_dram[0].start/size
reserve_mem_start = start + size - ALLOC_ALIGN;           // :191  DDR 顶端再减 4K
reserve_mem_start = (reserve_mem_start - ALLOC_ALIGN) & ~(ALLOC_ALIGN-1);  // :198
reserve_mem_free  = reserve_mem_start;                    // :206
// reserve_mem_alloc(size)  :90
size = (size + ALLOC_ALIGN-1) & ~(ALLOC_ALIGN-1);        // :101
reserve_mem_free -= size + ALLOC_ALIGN;                  // :109  向下生长
ptr = (void *)reserve_mem_free;                         // :110  返回新游标
```
- `set_reserve_mem_bound(get_ddr_free(&ddr_free, ALLOC_ALIGN) + CONFIG_RESERVE_MEM_GAP)`（`:175`）设下界；
- `adjust_reserve_mem_start`（`:125`）在 `ddrsize == 768M 或 1.5G` 时按 `mmz=` 调整起始（本机 1G 不触发）；
- `CONFIG_HIBERNATE`/`CONFIG_HISI_SNAPSHOT_BOOT` 打开时会先分配几块 `reserve_*`。

[推断] 于是 `DISPLAY_BUFFER_HD` 的物理地址 = `reserve_mem_start − Σ(之前分配 size+4K) − (本次 size+4K)`，
在**给定 `mem=`、DDR 顶端物理基址、分配序列**时是确定的；`mem=` 由 `bootargs.bin`（我们可控制）提供。

[未知] 仍未定的项，不编造：
1. DDR 顶端在本机 Linux 视角的**物理基址**。`source/boot/product/driver/include_inc/hi_common.h:14`
   `#define MEM_BASE (0x80000000)` 与 `docs/040`(`smem_start=0x3C55C000`)、`docs/041`(`0x3f6ce000`) 量级不符，
   疑有 CPU 高位映射 / LMI 别名 / 内核 `mem=` 与 SDK 视角差异；两者换算关系未测。
2. boot 阶段走到 `HI_GFX_ShowLogo` **之前**的全部 `reserve_mem_alloc` 调用及各自 size（尤其 hibernate 项）。
3. 短接刷机 `bootcmd` 分支是否执行到 `HI_GFX_ShowLogo`（VO 是否被点亮）——决定 `G0_ADDR` 此时是否有效。
4. 跨次上电稳定性（`docs/040` 与 `docs/043` 两个实测值已不相等）。

---

## 3. 对「刷机阶段显示进度」的判定

**硬件本质（[观察]+[推断]）**：VO 开启后，屏幕 = `G0_ADDR` 显存的实时映射。
因此**进度显示的最简形式是往活跃显存写纯色**（`mw.l <G0_ADDR值> <ARGB> <count>`），
**不是**「生成/引用多张图片」——用户对「阶段图更复杂」的质疑在原理上是对的，`docs/046` 的阶段图只是
在 VO 未被点亮的刷机分支下、借 fastboot 的 logo 绘制能力做的一种**间接折中**。

**但「只改 bootargs.bin 用 `mw.l` 实时变色」仍被两个前提卡住（[推断]，与 `docs/045` 一致）**：

| 前提 | 现状 | 证据 |
|---|---|---|
| P1 刷机 `bootcmd` 执行时 VO/HDMI 已初始化、正在扫描显存 | **未满足** | `docs/036 §4.2` 刷机分支不做显示初始化；用户实测刷机时「背光都不亮」（#17）。VO 没开 → 写显存不亮。 |
| P2 `G0_ADDR` 的物理地址静态可知且稳定 | **未满足** | 地址 = `reserve_mem_alloc` 运行时分配（§2）；`docs/040` `0x3C55C000` ≠ `docs/043` `0x3f6ce000`，未证稳定。 |

**分叉结论**：
- 若团队并行核查证实「短接 fastboot 在 `bootcmd` 之前已显示 logo / 点亮 VO」且地址可由固定 `mem=` 推导 →
  在 `bootcmd` 各 `fatload`/`mmc write` 步骤间插 `mw.l` 换 ARGB，可得**真·实时变色进度**（无图片、无 pstore、不动 p1），
  这是最贴合用户直觉的方案；地址仍须用一次在线实测（`docs/040` 方法读 `G0_ADDR`/fb 物理地址）标定后再写死。
- 若未点亮（当前 `docs/036 §4.2` 倾向此）→ 实时变色不成立，只能走
  `docs/039`/`docs/046` 的**零风险方案**：分阶段 U 盘包 + 每阶段写一张**纯色** logo 到 p5 + reset，
  卡死后一次正常开机由 fastboot 画出「卡在第 N 步」的颜色/文字（实证基础 `docs/039` 社区两张图真机验证）。
  纯色 logo 可用仓库内 `scripts/make-flash-logo.py` 生成，仍无需复杂图片资源。
- 真·实时文字日志（非颜色）需要改 p1（`docs/037` NO-GO，显示实现不在这份 p1）或引入已打通显示栈的
  Linux 中间系统写 `/dev/fb0`（`docs/040` 实证），**都不是只改 bootargs.bin**。

---

## 4. 与 045 的互补与留痕

- **[观察] vs [推断] 分层坐实**：`docs/045` 从**二进制**证明「我们备份的 `3.3.0-00786` p1 里没有显示实现的机器码」；
  本文从**源码**给出「含 higo/GFX 模块的构建如何绘制」。硬矛盾（「原厂通电即显示」是真事 vs 「0 引用」）
  由此消解：显示发生在**另一份 fastboot 构建**（`docs/038` 板子页 boot log 的 `3.3.0-00709`，
  运行时打印 `=====FILE: higo/adp_gfx.c`）或运行时 fastapp/内核 hifb logo 图层交接，而非我们备份的这份 p1。
- **不编造地址**：`G0_ADDR` 确切写入值、DDR 顶端换算、跨次上电稳定性一律标 `[未知]`，待在线实测闭合。
- **REA 留痕**：本文全部「源码事实」为 `[观察]`（文本可读、行号固定）；「绘制发生在正常开机分支、
  fastboot 构建对应关系、mw.l 前提」为 `[推断]`；「地址数值、时序、稳定性」为 `[未知]`。未用 strings/文件名
  单独推断行为；每条结论都落到具体函数与寄存器写。

---

## 5. 下一步（朝「刷机可见」收敛）

1. 等团队并行核查「短接 `bootcmd` 前 VO/HDMI 是否已点亮、`higo/adp_gfx.c` 在 boot log 中的时序」，
   用来源链接补到本文 §3 的分叉判断（这是唯一决定性未知）。
2. 若成立，用 `docs/040` 在线方法读一次 `G0_ADDR`/fb 物理地址标定，固定 `mem=` 后在 `flash.env`
   的 `bootcmd` 各步间插 `mw.l` 换色，做一版可刷包验证实时进度。
3. 若不成立，落实 `docs/046` 的「阶段纯色 logo + reset」零风险方案（用 `make-flash-logo.py` 出纯色图，
   不引入复杂图片资源），首次给出卡死阶段可判读。
4. 全程遵守 `AGENTS.md`：不删文件、临时产物只在 `TMP/`、显式 `git add <具体路径>`、提交前 `git show --stat`
   核对、仓库内不出现本机绝对路径/IP/用户名。
