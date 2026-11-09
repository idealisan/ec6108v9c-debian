# display_chain.md — 逐函数显示链还原（全量反汇编证据）

> 标注遵循 docs/033 §2。每行"函数@地址 → 具体指令 → 调用谁 → 数据从哪来 → [观察]/[推断]"。
> **一切功能结论都来自逐条指令**，字符串/符号名只用于定位函数入口，不作为行为证据。
> 反汇编行可在 `disasm_p01.txt`、`disasm_p11.txt`、`display_funcs_p11.txt` 按 VA 检索核对。

---

## 0. 必须先说清的覆盖度结论（否则整条链无从谈起）

### [观察] `p01_fastboot.img`（stock 1MiB hiboot）**不含显示实现代码**
全量线性 sweep（262,144 字全覆盖，`disasm_p01.txt`）+ 调用图/字面量全量统计
（`analysis_p01.json` / `ledger.json`）给出：

- 262,144 个 4 字节字全部逐条反汇编；识别 2,054 个函数、8,340 条 BL/B 调用边、
  1,465 个不同 BL 目标、6,334 条 PC-relative `ldr`、4,924 个字面量池字。
- **VO/VDP/HDMI 寄存器基址字面量计数全为 0**：
  `0xf8cc0000`=0、`0xf8ce0000`=0、`0xf8ce1800`=0、`0xf9000000`=0；
  仅 CRG/系统控制 `0xf8a2xxxx` 类 117 个字面量命中（含 `0xf8a22000`×14）。
- **303 个显示符号名（`PRODUCT_DisplayInit`/`Logo_Main`/`HI_UNF_HDMI_*`/
  `HDMI_Display`/`hdmi_Disp2EncFmt`/`TX_SetHDMIMode`/`TX_PHY_WriteRegister`/
  `SW/HW_ResetHDMITX`/`siiSetVideoPath`/`pdm_tag`/`HIFB_DispBuf_HD`/`fastapp_entry` 等）
  全部落在 0x79C80..0x83xxx 的 STR 数据区**，对其中每一个做全字面量池 xref 检查：
  **0 个代码引用**。它们是 20 字节定长的 stripped 符号名池 / 模块清单残留，与
  `docs/045 §1.2` 的"显示实现未链接进本 p1 镜像"结论一致，本轮用**全覆盖反汇编**独立坐实。
- 该文件是 `Fastboot 3.3.0` U-disk **刷机分支** build；`PRODUCT_DisplayInit`、
  `Logo_Main` 等入口函数**没有函数体**。

### [推断] 因此"hiboot 点亮 → VO → HDMI TX/PHY → 内核 fb0"这条链
**无法在 p01 内逐函数走通**（不是没找全，是确证不存在）。真正的显示实现在两处：
1. **内核侧（p11_vmlinux.bin, 3.10.0_s40）**：完整 hifb/VO/VDP/HDMI/PDM 私有栈，
   本轮已用 kallsyms 实名 + 全量反汇编还原，见 §2。
2. **另一份 fastboot build**：社区 `TMP/community-restore/fastboot.bin` 含
   `HI_GFX_ShowLogo`(0x6C1C8)、`PRODUCT_DisplayInit`、`0xf9000000` 字面量×4，
   而 p01 无——两者是"同一 U-Boot 代码库的不同 build"（docs/045 §1.6/§(d)），
   社区这份才带图形/显示初始化入口。p01 与社区 `mv100/fastboot.bin` 的 sha 不同
   (`bac0be9f…` vs `fd5b4ac6…`/`3bded87f…`)，确认是不同构建。

### [观察] 为什么"扫不到 0xf8cc0000 字面量"却仍有显示
内核通过 `movw/movt` 构造寄存器基址并交给 `ioremap`，基址存进**运行时全局指针**，
不是静态字面量。`DISP_Init` 的 `movw r0,#0; movt r0,#0xf8cc; bl DISP_HAL_Init`
（下 §2.1）即证据；全 vmlinux 有 18 处 `movt #0xf8cc/#0xf8ce`。
所以"字面量=0"≠"没有显示代码"，但 p01 连 `movw/movt #0xf8cc` 也 0 处，
且显示名 0 代码引用——两条独立证据共同锁定 p01 无显示实现。

---

## 1. 启动/交接链（原厂 3.10 vs 主线 6.x）— 见 FINDINGS.md §7，此处给反汇编锚点

| 阶段 | [观察] 原厂 3.10 | [观察] 主线 6.x |
|---|---|---|
| 容器 | p11 boot.img `ANDROID!` @0：kernel_size=7,898,576、kernel_addr=**0x03E08000**、ramdisk_addr=0x04E00000、tags_addr=0x03E00100、page_size=2048 | uImage `hi_kernel.bin`：load=entry=**0x02000000** |
| 内核真身 | 内嵌 uImage(load=ep 0x02000000, zImage gzip piggy @payload+0x5894)→解压出 vmlinux LMA **0x80008000** | zImage+appended DTB，链接 0xC0008000 系（本项目 DTB `/chosen/bootargs` + `/memory@0`） |
| 启动命令 | `bootm`：Android boot.img 装载到 0x03E08000，ATAG 列表 @0x03E00100 | p2 env `bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0` |
| cmdline | boot.img cmdline `coherent_pool=2M console=ttyAMA0,115200 blkdevparts=<16分区>`，另由 env `bootargs_1G=mem=1G mmz=ddr,0,0,400M` 合并 `mem=`/`mmz=`，**无 root= 在 boot.img 头** | DTB `/chosen/bootargs=model=mv100 clk_ignore_unused console=tty0 console=ttyAMA0,115200 root=mmcblk0p8 ... blkdevparts=<8分区> mem=1G` |

详见 FINDINGS.md §7（含"6.x 是否启动"的静态不可判定性）。

---

## 2. 内核侧逐函数显示链（p11_vmlinux.bin, kallsyms 实名, 全部出自全量反汇编）

> 内核 LMA = 0x80008000；`SYM` 由 kallsyms 重建（62,959 符号，__kstrtab 80/80 oracle，
> DELTA=0）。下列 VA 均可在 `disasm_p11.txt` / `display_funcs_p11.txt` 检索。

### 2.1 DISP 初始化 → VO 寄存器基址映射
`DISP_Init` @0x805DB2D4（`display_funcs_p11.txt`）：
```
0x805DB324 movw r0, #0          ; [观察] 构造 0xf8cc0000
0x805DB328 movt r0, #0xf8cc
0x805DB32C bl   0x805A95DC       ; -> DISP_HAL_Init(0xf8cc0000)  [推断]ioremap VO/VDP 寄存器区
0x805DB338 add  r0, r5, #0x10c0
0x805DB33C add  r0, r0, #0x10
0x805DB340 bl   0x805A6C68       ; -> DISP_HAL_GetOperation
0x805DB35C bl   0x805DA894       ; -> DispInitDisplay(0)
0x805DB360 mov  r0, #1
0x805DB364 bl   0x805DA894       ; -> DispInitDisplay(1)
0x805DB368 bl   0x805D156C       ; -> DISP_ISR_Init
0x805DB394 bl   0x80088D8C       ; -> request_threaded_irq(0x7a,...)
0x805DB3A0 bl   0x805D60B8       ; -> DispResetHardware
```
数据来自：常量 `0xf8cc0000`（[观察] 立即数）；[推断] 传入 DISP_HAL_Init 后存全局
`gopVDPAllReg`-类指针，供后续 VO 图层寄存器访问。

### 2.2 VO 图层 G0 显存地址寄存器（**决定性：偏移 = +0x6010，不是 +0x494**）
三处独立函数、三份内核一致（[观察] 指令级）：

**(a) `VDP_GFX_SetLayerAddr` @0x805B6A84**
```
0x805B6AA4 movw r3, #0x8758      ; 0x81138758 = 全局 VO 基址指针变量地址
0x805B6AA8 movt r3, #0x8113
0x805B6AB0 lsl  r0, r0, #0xb     ; layer<<11 = layer*0x800 (CONFIG_HIFB_GFX_OFFSET)
0x805B6AB4 ldr  r1, [r3]         ; r1 = VO 寄存器基址(运行时 ioremap 值)
0x805B6AC0 lsr  r0, r0, #2
0x805B6AC4 add  r1, r1, #0x6000
0x805B6AC8 add  r1, r1, #0x10    ; +0x6010 = G0_ADDR  [观察]
0x805B6ACC str  ip, [r1, r0, lsl#2]  ; 写显存物理地址到 G0_ADDR + layer*0x800
0x805B6AD4 add  ip, r3, #0x6000
0x805B6AD8 add  r3, ip, #0x1c    ; +0x601C = G0_STRIDE
0x805B6ADC ldr  r1, [r3, r0, lsl#2]
0x805B6AE4 strh r2, [fp,#-0x14]  ; 低 16 位写 stride
0x805B6AEC str  r2, [r3, r0, lsl#2]
```
**(b) `OPTM_VDP_GFX_SetLayerAddrEX` @0x805F4178**
```
0x805F4198 movw r2,#0x1c24; 0x805F419C movt r2,#0x8114   ; 0x81141c24 全局 VO 基址指针
0x805F41A4 ldr  ip,[r2]
0x805F41AC add  r1, ip, #0x6000
0x805F41B0 add  r3, r1, #0x10          ; +0x6010  [观察]
0x805F41B4 str  r2, [r3, r0, lsl#11]   ; G0_ADDR + layer*0x800
```
**(c) `OPTM_VDP_GFX_GetLayerAddr` @0x805F41D8（**内核回读显存地址的正是这里**）**
```
0x805F4200 movw ip,#0x1c24; 0x805F4204 movt ip,#0x8114
0x805F4208 ldr  r2,[ip]
0x805F420C add  r3, r2, #0x6000
0x805F4210 add  ip, r3, #0x10          ; +0x6010  [观察]
0x805F4214 ldr  r2, [ip, r0, lsl#11]   ; 读出 G0 图层显存物理地址
0x805F421C ldr  r3,[fp,#-0x10]; 0x805F4220 str r3,[r1]  ; 回灌给调用者 out 参数
```
交叉验证：
- recovery 3.10 (`TMP/recovery-deep/disasm-final.log:669`) `OPTM_VDP_GFX_SetLayerAddrEX`
  @0xC032912C：`add r3,r3,#0x6000; add r3,r3,#0x10; add r0,r3,r0,lsl#11`。
- 社区 4.4.35_ecoo @0xC06DB3BC：`add r3,r3,#0x6000; ... add r3,r3,#0x10;
  strne r2,[r3,r0,lsl#11]`。
- SDK `hi_reg_vdp.h` 全 struct（含 `Reserved_57[1840]`）算出 G0_CTRL=+0x6000、
  G0_ADDR=+0x6010、G0_STRIDE=+0x601C、G0_IRESO=+0x6020，与 `add #0x6000;add #0x10` 吻合。

> **[推断/重要] 与既有文档、与我们的运行时驱动的冲突（详见 FINDINGS.md §D 一锤定音）**：
> `docs/023 §4.2` 用"605 个 u32 成员 / 0x974 窗口"的**紧凑结构**算出 G0_ADDR=+0x494；
> 本轮证明那正是"删掉所有 `Reserved_*` 空洞后只数具名 union"的压缩视图（compact
> 恰为 605 u32=0x974 B），而真实 `S_VDP_REGS_TYPE` 含 `Reserved_57[1840]` 等空洞把
> G0 推到 +0x6000 段；full-struct 的 +0x494 实为 `GP1_PARARD`（GP 层参数读寄存器），
> +0x49c/+0x4a0 落在 `Reserved_12` 空洞内——**不是 G0_ADDR**。
> `patches/kernel/hi3798mv100-hdmi-console.c:54-56` 照抄 +0x494/+0x49c/+0x4a0，
> 且 `:53` `VO_REG_SIZE=0x1000`、`:207` 只 `ioremap(0xf8cc0000, 0x1000)`（够不到 +0x6010）。
> **两处叠加可解释"驱动读到 0 / 拿不到有效显存"**——但需真机读 +0x6010 确认（UNKNOWNS 优先级 3）。
> backport 驱动与 legacy 绿带判据应改用 +0x6010 系列并把 ioremap 扩到 ≥0x7000/建议 0xfff0。

### 2.3 HDMI TX / PHY 初始化（内核侧）
- `HI_DRV_HDMI_Init` @0x80584DC4、`HI_DRV_HDMI_Open` @0x80584874、
  `HDMI_DRV_ModInit` @0x80589420、`SI_TX_PHY_INIT` @0x805A5438（caller 0x8059BDA0）。
- `MCE_ModuleInit` @0x8089B608/0x8089B614 依次 `bl HI_DRV_HDMI_Init(0x8089B608)`、
  `bl HI_DRV_DISP_Init(0x8089B614)`（[观察] 调用边）——即开机 MCE 模块把 HDMI+DISP 拉起。
- 完整函数体见 `display_funcs_p11.txt`（按实名检索）。[推断] 具体 PHY 寄存器写序列与
  EDID/HPD 读取逻辑需结合 SDK `hdmi_1_4/` 源码逐条对应，本轮静态未逐字节落表。

### 2.4 fb0 注册链（内核如何拿到显存并注册 /dev/fb0）
`HIFB_DRV_ModInit` @0x80609EB0（`display_funcs_p11.txt`）：
```
0x80609EE0 bl 0x806012F4   ; -> HIFB_DRV_GetDevOps
0x80609EE8 bl 0x805FFF48   ; -> HIFB_DRV_GetTdeOps
0x80609EF0 blx r3          ; 通过 DevOps 函数指针初始化
0x80609F04 bl 0x80602A60   ; -> hifb_logo_init   [观察]
0x8060A368 ldr lr,[fp,#-0x54]; 0x8060A36C str lr,[r4,#0xf0]   ; fix.smem_start 来源值
0x8060A370 bl 0x80602438   ; -> hifb_buf_map
0x8060A378 str r0,[r4,#0x280]          ; fb_info 内保存映射结果  [观察]
0x8060A3A0 add r0,r4,#0x214; 0x8060A3AC bl 0x8036C104 ; -> fb_alloc_cmap
0x8060A3E0 mov r0,r4
0x8060A3E4 bl 0x8036A380   ; -> register_framebuffer  [观察] 注册 /dev/fb0
```
`hifb_buf_map` @0x80602438：
```
0x80602458 bl 0x805520E4   ; -> HI_DRV_MMZ_Map   [观察] 显存来自 MMZ 运行时映射
0x80602464 ldreq r0,[fp,#-0x1c]
```
`hifb_logo_init` @0x80602A60：通过全局 ops 表 `0x811433C8+0x40` 间接调用
（`blx r2`），配合 `hifb_set_logosd`/`hifb_assign_dispbuf`/`HifbSetLogoLayerEnable`
处理 logo 图层。

> **[推断] fb0 的 smem_start 来源**：内核 hifb 驱动经 `HI_DRV_MMZ_Map` 从 **MMZ 运行时
> 映射**取得，并经 `register_framebuffer` 注册 `/dev/fb0`。这与在线实测
> `smem_start=0x3C55C000`（`TMP/fb-report-1.txt`, docs/021:16）一致——即 **0x3C55C000
> 是社区/内核 hifb 自己分配的 fb0 mmap 基址，不是 hiboot 交接来的那块**。

### 2.5 交接链核心：`pdm_tag` 具名预留内存表（**动态交接，非硬编码**）
`pdm_reserve_mem` @0x80F0378C（全函数反汇编见 `display_funcs_p11.txt`）：
```
0x80F037AC movw r0,#0x214; 0x80F037B4 movt r0,#0x80d0 ; =0x80d00214 = "pdm_tag" 串VA [观察]
0x80F037B0 mov r1,r4; 0x80F037B8 mov r2,#0x200
0x80F037BC bl 0x8005BA58    ; -> get_param_data("pdm_tag", buf, 0x200)  [观察]
0x80F0382C bl 0x800266C8    ; -> pdm_read_item 逐个解析 <name>=0x<addr>,0x<len>  [观察]
0x80F0384C bl 0x8034D900    ; -> simple_strtoul(...,16) 解析地址
0x80F03860 bl 0x8034D900    ; -> simple_strtoul(...,16) 解析长度
0x80F038A8 bl 0x80B390DC    ; -> printk("pdm: name:%s, phyaddr:0x%08x, addrlen:0x%08x ...")
0x80F038EC bl 0x800F89EC    ; -> memblock_reserve(addr,len)  [观察] 按名字预留每块
```
`0x80F03928`（early init）依次 `bl pdm_reserve_mem` → `initmrd_reserve_memory` →
`initfile_reserve_memory` → `hisi_declare_heap_memory`（[观察] 调用边，见 `disasm_p11.txt`）。

 hiboot 侧（SDK 源码 `TMP/sdk-src/`，[观察] 为真源码行）：
 - `reserve_mem.c:90-123` `reserve_mem_alloc()`：从 DDR 顶 `reserve_mem_start`
   （mem=1G → 0x3FFFE000）按 `size+ALLOC_ALIGN` 向下生长——**动态分配**。
 - `hi_gfx_layer.c:637` `HI_GFX_RESERVE_Malloc(size, DISPLAY_BUFFER_HD)`、
   `hi_gfx_mem.c:64` → `drv_pdm.c:2294` `HI_DRV_PDM_AllocReserveMem(name,len,&phy)`
   把 `{Name, PhyAddr, Len}` 记入 `g_stResBuf[]`（`:2312-2316`）。
 - `drv_pdm.c:2376-2410` `HI_DRV_PDM_SetTagData()` 序列化成
   `version=1.0.0.3 <Name>=0x<PhyAddr>,0x<Len> ...`，
   `:2406` `set_param_data("pdm_tag", PdmTag, len)` 交给内核（ATAG/param 块）。
 - `hi_gfx_layer.c:429` `OPTM_GfxSetLayerAddr(s32DataId, u32ScreenAddr)`（`:656` 来源）
   → `drv_hifb_adp.c:2491` → `drv_hifb_hal.c:583` 写 `G0_ADDR+layer*0x800`。

> **[推断] 这就是用户要的"动态交接过程"**：地址不是硬编码常量，是 hiboot 用
> `reserve_mem_alloc` 从 DDR 顶端动态分配的具名缓冲（`HIFB_DispBuf_HD` 等），
> 通过 `pdm_tag` 参数块以 **名字→(物理地址,长度)** 表交给内核；内核 `pdm_reserve_mem`
> 解析后 `memblock_reserve`，hifb 再按名取用/MMZ 映射并注册 fb0。
> 实固件佐证：p01/社区 fastboot.bin 都含 `pdm_tag`/`HIFB_DispBuf_HD`/`set_param_data`
> 串（此处仅作**定位**，行为结论来自上面逐条指令）。

---

## 3. 数据从哪里来（汇总，[观察]/[推断] 标注）

| 数据 | 来源 | 标注 |
|---|---|---|
| logo 位图 | p7 分区单张 1920×1080 JPEG（docs/045 §1.2，LOGO_TABLE） | [观察]（文档既有）+[未知] 解码器所在二进制 |
| DISP 时序 / EDID | p5 baseparam `BASE_TABLE_DISP`（TIMING_* 全 0、VIRSC 1280×720）+ sink EDID 运行时读取 | [观察]+[推断]（docs/023:145 时序由 EDID 定） |
| 显存物理地址 | hiboot `reserve_mem_alloc` 动态分配，`pdm_tag` 具名表交接 | [观察] 源码指令 + [推断] 交接语义 |
| VO 图层写入 | `G0_ADDR(+0x6010)+layer*0x800` / `G0_STRIDE(+0x601C)` / `G0_IRESO(+0x6020)`，基址 `0xf8cc0000`(DISP ioremap) | [观察] 三内核一致 |
| fb0 smem_start | 内核 `HI_DRV_MMZ_Map` 运行时映射（社区在线实测 0x3C55C000） | [观察]+[推断] |
| 几何 1920×1080@7680 a8r8g8b8 | 社区在线 fb-report-1 + p7 JPEG 尺寸 | [观察]（既有实测） |

---

## 4. 明确"没走通/未逐字节落表"的部分（诚实清单，不假装全查完）

- [未知] p01 **无** `PRODUCT_DisplayInit`/`Logo_Main`/`HI_UNF_HDMI_*`/`TX_PHY_*` 函数体，
  故"读 p7→解 LOGO_TABLE→写显存→配 VO→HDMI TX/PHY→EDID/HPD→输出"的 **hiboot 侧
  逐函数链在本镜像内不存在**，无法逐函数走通；能走通的只有内核侧（§2）。
- [推断] HDMI TX/PHY **逐寄存器写入值/偏移序列** 本轮未在 §2.3 逐字节落表（函数体已在
  `display_funcs_p11.txt` 全量给出，可继续逐条补），需与 SDK `hdmi_1_4/` 源码对齐。
- [未知] `reserve_mem` 在到达 `HI_GFX_ShowLogo` 前的**完整分配序列及各块 size** 未逐项
  枚举（docs/048 §2 亦列此为 [未知]），故"某次开机显存的绝对地址"静态不可精确复现。
- [未知] `0xf9000000`（社区 fastboot 有、p01 无）与 `0xf8cc0000` 是否两个独立寄存器窗口
  未决；本轮 p11 内核只用 `0xf8cc0000`（DISP_Init）。
- 上述均列入 `UNKNOWNS.md`，并写明所需真机动作。
