# FINDINGS.md — finding ledger + 明确结论

> 全量反汇编工程（`disasm_p01.txt` 262,144 行 / `disasm_p11.txt` 3,979,360 行）的覆盖度台账
> 与 6 个明确回答。标注：[观察]=指令/立即数/寄存器偏移/调用边；[推断]=据观察推的功能；
> [未知]=静态不可定、需真机。
> 机器可读版本：`ledger.json` / `analysis_p01.json`。

---

## A. 覆盖度 ledger（可核对，不假装查完）

### A.1 `p01_fastboot.img`（1 MiB 裸 ARM，load 0x00C00000）
| 指标 | 数值 | 证据 |
|---|---|---|
| 4 字节字总数 | **262,144** | `disasm_p01.txt` 行数 = 262,144（逐字全覆盖，不挑不跳） |
| capstone 线性 sweep 覆盖指令 | **262,144 行全部写出** | 同上；CODE 块出指令，STR/FILL/DATA 块以 `.word` 逐字列出并在头部 `SKIPCODE` 登记 |
| 识别函数入口 | **2,054** | BL 目标 ∪ prologue(stmdb sp!,{..lr}/mov ip,sp) ∪ 向量表目标 ∪ reset 目标；`functions_p01.tsv` 2054 行 |
| BL/B 调用边 | **8,340** | `calls_p01.tsv` 全量 |
| 不同 BL 目标 | **1,465** | 同上 |
| PC-relative `ldr` | **6,334** | `analysis_p01.json` |
| 字面量池字 | **4,924** | 同上 |
| 含 MMIO 字面量的函数 | **50**（117 个字面量命中，全是 0xf8a2xxxx CRG/系统控制） | `display_funcs_p01.txt`（逐个反汇编 50 个） |
| **VO/HDMI 寄存器常量** | **0xf8cc0000=0, 0xf8ce0000=0, 0xf8ce1800=0, 0xf9000000=0** | 四份 fastboot 交叉扫描 |
| **显示符号名代码 xref** | **0**（303 个显示名 token 全在 STR 数据区） | 全字面量池 xref 检查 |
| 非 CODE 显式登记区间 | 见 `ledger.json p01.skip_intervals` | FILL(0x97000..0x100000)、STR(多处)、0x1000..0x2000 填充 |

**已分析 M**：全部 2,054 个函数均有函数级反汇编条目（`functions_p01.tsv` +
`disasm_p01.txt` 全量逐字）。**其中显示相关 K = 0 个有函数体的显示函数**：
50 个 MMIO 候选函数逐个反汇编（在 `display_funcs_p01.txt`），结论均为 CRG/时钟/系统控制
初始化，无 VO/HDMI 图层或显存操作（见 display_chain.md §0）。
**未逐基本块分析**：2,004 个与显示无关的函数（全量反汇编已给出，但未逐条读控制流）——
显式登记，不假装逐个精读。

### A.2 `p11_vmlinux.bin`（17,432,904 B，内核 3.10.0_s40，LMA 0x80008000）
| 指标 | 数值 | 证据 |
|---|---|---|
| kallsyms 符号 | **62,959**（`__kstrtab` oracle **80/80**，base=0x80008000, DELTA=0） | `functions_p11.tsv` 62,135 行（去重后实名） |
| code span 线性 sweep | **3,979,360 行**（`_stext` 0x800081C0 .. `_einittext` 0x80F36240） | `disasm_p11.txt`；span 外区间头部 `OUTSIDE` 登记 |
| 显示相关实名函数 | **1,420** | `display_funcs_p11.txt` 逐个全函数反汇编（含字面量池） |
| 显示链关键函数逐个精读 | VDP_GFX_SetLayerAddr / OPTM_VDP_GFX_SetLayerAddrEX / OPTM_VDP_GFX_GetLayerAddr / DISP_Init / DISP_HAL_Init / HI_DRV_HDMI_Init / HI_DRV_HDMI_Open / HDMI_DRV_ModInit / SI_TX_PHY_INIT / HIFB_DRV_ModInit / hifb_logo_init / hifb_buf_map / register_framebuffer / pdm_reserve_mem / MCE_ModuleInit 等 | display_chain.md §2 逐条指令 |

**未逐基本块分析**：62,135 个函数中除显示链相关外，其余只做了全量线性 sweep（逐条指令
已给出），未逐基本块读控制流。显式登记：这是"全量反汇编 + 显示链定向精读"，
不是"逐个函数人工精读 6 万函数"。
**辅助交叉**：recovery 3.10 vmlinux（`TMP/recovery-deep/`）、社区 4.4.35_ecoo vmlinux
（uImage 解压）用于 G0 偏移三内核交叉验证；p03__sbin__recovery (ELF) 用于确认
"内核已注册 fb0 后走 FBIOGET_* blit"前提；p05_baseparam 为 DISP 参数表（数据，未反汇编代码）。

---

## B. 明确回答（用户/team-lead 的 4+2 个问题）

### 【1】hiboot 把 logo/显存画到哪个物理地址，通过哪个 VO 图层寄存器交接
- **[观察] 交接寄存器 = VO GFX 图层 0（G0，非 GP0）的 ADDR 寄存器，偏移 = `VO_base + 0x6010`（+ layer×0x800）**：
  三份真实内核（`VDP_GFX_SetLayerAddr` @0x805B6A84、`OPTM_VDP_GFX_SetLayerAddrEX`
  @0x805F4178、`OPTM_VDP_GFX_GetLayerAddr` @0x805F41D8）反汇编一致为
  `add rX,rX,#0x6000; add rX,rX,#0x10; str/ldr [rX, layer<<11]`。
  `VO_base=0xf8cc0000` 由 `DISP_Init @0x805DB2D4` 的 `movw r0,#0;movt r0,#0xf8cc;
  bl DISP_HAL_Init` 经 ioremap 得到（18 处 `movt #0xf8cc/#0xf8ce`）。
  G0_STRIDE=+0x601C、G0_IRESO=+0x6020。
- **[推断] 不是 +0x494**：`docs/023 §4.2` 用"605 成员/0x974 窗口"紧凑 struct 推出的
  +0x494 与真实内核全 struct（含 `Reserved_57[1840]`）不符；
  `patches/kernel/hi3798mv100-hdmi-console.c:54` 照抄 +0x494 且 `:53` 只 ioremap 0x1000，
  **既读错寄存器又够不到 +0x6010**——这是运行时驱动"读到 0"的静态可解释嫌疑（需真机确认）。
- **[观察] 本 p01 镜像内没有该写入**：p01 全量 sweep 中 0xf8cc0000 字面量=0、显示名 0 代码
  xref，即 `PRODUCT_DisplayInit`/`Logo_Main` 无函数体（display_chain.md §0）。写 G0 的动作
  发生在带显示实现的另一 fastboot build / 内核。

### 【2】地址是硬编码常量还是动态分配？跨次是否稳定？
- **[推断] 动态分配，非硬编码**：hiboot 侧（SDK 真源码 `reserve_mem.c:90-123`
  `reserve_mem_alloc()` 从 DDR 顶 `reserve_mem_start`（mem=1G→0x3FFFE000）按
  `size+0x1000` 向下生长；`hi_gfx_layer.c:637` `HI_GFX_RESERVE_Malloc(size,
  DISPLAY_BUFFER_HD)` → `drv_pdm.c:2294` `HI_DRV_PDM_AllocReserveMem(name,len,&phy)`。
- **[观察] 交接载体 = `pdm_tag` 具名预留内存表**：`drv_pdm.c:2376-2410`
  `HI_DRV_PDM_SetTagData()` 序列化 `version=1.0.0.3 <Name>=0x<PhyAddr>,0x<Len> ...`，
  `:2406` `set_param_data("pdm_tag",...)`；内核 `pdm_reserve_mem` @0x80F0378C 反汇编：
  `get_param_data("pdm_tag",buf,0x200)` → `pdm_read_item` → 两次 `simple_strtoul(...,16)`
  → `printk("pdm: name:%s,phyaddr:0x%08x,addrlen:0x%08x")` → `memblock_reserve(addr,len)`。
  `[推断]` 地址按**名字**(如 `HIFB_DispBuf_HD`)交接，不是固定物理常量。
- **[推断] 跨次稳定性：给定固定 mem= + 固定 hiboot 分配序列时确定，但静态不可证**：
  `reserve_mem_alloc` 是确定性算法（docs/048 §2 已用多份 mem=1G 日志复现 Reserve Memory
  表完全一致），但"到达 HI_GFX_ShowLogo 前的完整分配序列/各块 size"未逐项枚举
  （docs/048 §2 列此为 [未知]），故**绝对地址不能静态写死**。→ [未知] 需真机动作见 UNKNOWNS。

### 【3】内核侧 fb0 smem_start 的来源与交接值
- **[观察] 来源 = 内核 hifb 自己 MMZ 运行时映射**：`HIFB_DRV_ModInit` @0x80609EB0 →
  `hifb_logo_init` @0x80602A60 → `hifb_buf_map` @0x80602438 `bl HI_DRV_MMZ_Map`
  → `register_framebuffer` @0x8036A380。在线实测 `smem_start=0x3C55C000`
  （fb-report-1 / docs/021:16）。
- **[推断] `0x3C55C000` 与 `0x3f6ce000` 各是什么**：
  - `0x3C55C000` = 社区 4.4 **内核 hifb 自己**分配并注册 /dev/fb0 的 mmap 基址
    （smem_len 0xFD2000，双缓冲 1920×2160）；**不是 hiboot 交接值**（docs/041:63-66 已标 [推断]不可直接抄）。
  - `0x3f6ce000` = `HIFB_DispBuf_HD`（`/proc/msp/pdm` Reserve Mem Info，8,298,496 B ≈ 单帧
    1920×1080×4，docs/041:70,80-83），是**`pdm_tag` 具名预留缓冲**，最接近"hiboot 交接值"。
  - `0x0fc54000` = 短接态 recovery 3.10 内核**自己**初始化 hifb 的 fb0（1280×720@5120，
    docs/050:918），又一套独立路径，与正常开机无关。
- **[观察] 两份真值互异**（0x3C55C000 vs 0x3f6ce000，docs/041 自标），静态不能证明
  哪个等于 hiboot 留给主线 simplefb 的那块。

### 【4】主线 6.x simplefb：fb_base 写死还是运行时读寄存器？读哪个偏移？
- **[推断] 首选：不要写死，运行时读寄存器 / 解析 `pdm_tag`**：
  地址动态（§2）、`pdm_tag` 具名表是原厂实际交接机制。最稳是复刻社区内核做法——
  在 6.x 里解析 `pdm_tag` 取 `HIFB_DispBuf_HD=0x...` 的 PhyAddr/Size 注册 simplefb；
  或在运行时驱动读 VO G0 图层 ADDR 寄存器。
- **[观察] 若读寄存器，正确偏移 = `0xf8cc0000 + 0x6010`（+layer×0x800）**，
  且 `ioremap` 窗口须 ≥ 0x7000（现驱动 0x1000 不够）；G0_STRIDE=+0x601C、
  G0_IRESO=+0x6020。现驱动 +0x494 / +0x49c / +0x4a0 与 0x1000 窗口均需改。
- **[推断] 若必须写死**（8 候选已在 U 盘逐个试）：用 **A = 0x3f6ce000**
  （`HIFB_DispBuf_HD` 预留缓冲，唯一有交接语义），几何 **1920×1080 @ stride 7680,
  a8r8g8b8**，span 覆盖双缓冲 0xFD2000，且 DTB `reserved-memory` 加 `no-map`
  （docs/024:300-306）。**B=0x3C55C000 弃用**（内核自有 fb0，非交接值）。
- **[未知] 无论哪种，都先要确认"内核到底起没起"（见 §7 / UNKNOWNS 第 0 项）**——
  给没启动的内核调 fb_base 是方向性错误。

### 【5】原厂 hiboot 交接内核的完整启动链 vs 6.x 是否有冲突（team-lead 补充问题 1）
- **[观察] 原厂 3.10**：Android boot.img `ANDROID!` @0，`kernel_addr=0x03E08000`、
  `ramdisk_addr=0x04E00000`、`tags_addr=0x03E00100`、`page_size=2048`；内核是内嵌
  uImage(load=ep 0x02000000, zImage gzip piggy)，解压后 vmlinux **LMA=0x80008000**；
  `bootm` 用 **ATAG**(tags 0x03E00100) 传参；cmdline `coherent_pool=2M console=ttyAMA0
  blkdevparts=<16分区>`，`mem=1G mmz=ddr,0,0,400M` 由 env `bootargs_1G` 合并，**boot.img
  头里没有 root=/mem=**。
- **[观察] 主线 6.x**：uImage `load=entry=0x02000000`（`scripts/build-kernel.sh:19`）；
  p2 env `bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0`；
  **appended DTB**（zImage+DTB 拼接）+ `/chosen/bootargs`（含 `mem=1G`、
  `clk_ignore_unused`、`console=tty0`、`root=mmcblk0p8`、8 分区 blkdevparts）+
  `/memory@0 reg=<0x0 0x40000000>`；无 ATAG、无 `mmz=`。
- **[推断] 存在几处"约定不同"，静态可作为极早期挂掉的嫌疑点，但不能定论**：
  ① 内核 LMA：原厂 3.10 vmlinux 在 0x80008000，6.x 本项目按 DTB/常规在 0xC0008000 系
  （`kallsyms` 0xC0008000，见 docs/033）——装载地址/解压目标与 hiboot 对 uImage 的
  `bootm` 期望是否一致需核对；② 参数通道：原厂走 ATAG(tags 0x03E00100)，6.x 走
  appended DTB `/chosen/bootargs`，`CONFIG_ARM_APPENDED_DTB` 下 DTB cmdline 覆盖
  bootloader 传参（docs/018:119-123），若 hiboot 仍按 ATAG 布局放置参数、或 DTB append
  位置/totalsize 与内核期望不符，可能在极早期（`setup_machine_fdt`/`memblock` 之前）就挂；
  ③ `mem=1G` + `/memory@0` 两者一致性（docs/024:18,74-75 已核为一致）本身不是障碍。
- **[观察] 但这三点都只是"静态不变量对比"**：没有任何一条反汇编行能证明 6.x 在某条
  指令上失败——失败与否是运行时事件。→ 见 §6。

### 【6】静态反汇编能不能判定"6.x 内核是否启动失败"？需要什么真机信号？
- **[观察] 不能**。全量反汇编覆盖的是"如果执行，会做什么"，无法产出"是否真的执行到"。
  `docs/044:14-15` 的判断（「无 IP」+「无显示」同时出现，最简洁解是 6.x 根本没启动到
  userspace）是**配置层排除法推断**，不是反汇编证据。
- **[推断] 需要的真机信号（本机无串口，docs/006/013 硬约束）**：
  1. **绿带启动标记**（`docs/024 §6.1`）：`hi3798mv100-hdmi-console.c` 在 `subsys_initcall`
     把顶部 240 行刷纯绿——出现=内核跑到显示 initcall、显存地址正确；仍是 `Debian Linux`
     logo=内核没跑到该 initcall（→查 p6 写入/uImage/DTB，而非继续调显示）。
  2. **pstore/ramoops**：重启进社区系统读 `/sys/fs/pstore/dmesg-*`、`console-*`，
     找 `hi3798-fb: VO layer0: addr=...` 与内核早期 `printk`——有内核日志=内核起来了。
  3. **路由器新 IP / SSH**：出现=内核+rootfs+userspace 全通。
  4. 三者组合对应 `docs/026:86-93` 的 A(内核没起)/B(起到驱动但显示未绑)/C(全通) 判据。
- **[推断] 优先级**："内核是否启动" > "显存地址"。若绿带/pstore/IP 全无，
  应先查 §5 的装载地址/DTB/ATAG 交接，而不是继续试 fb_base 候选。

---

## C. 与既有文档的关系（不改口径，只更新优先级）
- **`docs/045`**：本轮用全覆盖反汇编**独立坐实**其"显示实现不在本 p1 镜像"结论
  （0 MMIO 常量 + 0 显示名代码 xref），非重复关键词碎片。
- **`docs/023 §4.2` / `docs/024 §6.1` 的 +0x494**：三份真内核反汇编 + SDK 全 struct
  一致给出 **+0x6010**；现运行时驱动 `hi3798mv100-hdmi-console.c` 的 +0x494 与
  0x1000 ioremap 需按 §4 修正（标 [推断]，真机确认前不改文件）。
- **`docs/041`/`049`/`050`**：0x3f6ce000(HIFB_DispBuf_HD) / 0x3C55C000(内核 fb0) /
  0x0fc54000(短接 recovery fb0) 三值互异、各属不同路径，本轮明确区分。
- **`docs/044`/`026`**：把"内核是否启动"列为比显存更靠前的未决项（UNKNOWNS 第 0 项）。

---

## D. 【一锤定音·backport 校验点】VO/VDP GFX 层寄存器真实偏移与 ioremap 覆盖

> 服务 `docs/052` / `patches/vendor-display/PORTING.md:18,22-27`（该文件明写"以研究员本轮
> FINDINGS 为准"）。本节用**逐字段结构体计算 + 三份真内核反汇编指令**定死，不靠关键词/符号名。

### D.1 两组偏移的来源与真值判定

| 组 | 值 | 出处 | 判定 |
|---|---|---|---|
| A（legacy/compact） | `G0_CTRL=+0x48c / G0_ADDR=+0x494 / G0_STRIDE=+0x49c / G0_IRESO=+0x4a0`，`VO_REG_SIZE=0x1000` | `docs/023 §4.2`、`patches/kernel/hi3798mv100-hdmi-console.c:53-56`、`docs/050:925` | **[推断] 错**（把保留空洞删掉后的"压缩视图"，非硬件偏移） |
| B（full/真实） | `G0_CTRL=+0x6000 / G0_ADDR=+0x6010 / G0_NADDR=+0x6018 / G0_STRIDE=+0x601c / G0_IRESO=+0x6020`，`CONFIG_HIFB_GFX_OFFSET=0x800` | 本轮 SDK `hi_reg_vdp.h` 逐字段计算 + 三份真内核 disasm | **[观察] 真值** |

**证据链（全部 [观察]，可在 `disasm_p11.txt`/`display_funcs_p11.txt` 按 VA 核对）：**

1. **SDK 结构体逐字段算偏移（本轮 `engine_full.py` + 独立复算脚本，两次一致）**：
   `TMP/sdk-src/source/common/drv/include/hi3798mv100/hi_reg_vdp.h` 只有 **一个**
   `typedef struct`（`:9971`），结尾 `} S_VDP_REGS_TYPE,S_VOU_CV200_REGS_TYPE;`（`:10693`）
   ——**两个 typedef 名共用同一结构**，`drv_hifb_hal.c:80-84` 的 `#ifdef CONFIG_HIFB_VERSION_1_0`
   只是选指针类型，不改变布局。逐字段累加（含所有 `unsigned int Reserved_NN[M]` 数组）：
   ```
   0x6000 G0_CTRL   0x6004 G0_UPD   0x6008 Reserved_58[2]
   0x6010 G0_ADDR   0x6014 Reserved_59 0x6018 G0_NADDR
   0x601c G0_STRIDE 0x6020 G0_IRESO  0x6024 G0_SFPOS ...
   ...
   full struct = 0xf354 B = 15,573 u32
   ```
2. **A 组是"删保留空洞后的压缩视图"，本轮精确复现其算法**：把所有 `Reserved_*`
   数组丢弃、只数具名 union，得到 **恰好 605 个 u32 = 0x974 字节**——与
   `docs/023 §4.2:107` 自述"共 605 个 u32 成员（窗口 0x974 字节）、成员偏移=4×序号"
   **逐字吻合**。压缩视图下 `G0_CTRL=+0x48c / G0_ADDR=+0x494 / G0_STRIDE=+0x49c /
   G0_IRESO=+0x4a0` 正好是 A 组。**即 docs/023 的错误根源＝用"4×序号"忽略了
   `Reserved_57[1840]` 等真实硬件保留空洞**（`Reserved_57[1840]`=0x1cc0 B 把 G0 从
   0x494 段整体推到 0x6000 段）。[推断] 这是静态推导方法错误，不是另一套硬件窗口。
3. **三份真内核反汇编一致**（`layer<<11 = layer*0x800`）：
   - 正常开机 3.10 (`p11_vmlinux.bin`) `VDP_GFX_SetLayerAddr @0x805B6A84`：
     `add r1,r1,#0x6000; add r1,r1,#0x10; str ip,[r1,r0,lsl#2]`（另 G0_STRIDE 走
     `add r3,ip,#0x1c`）；`OPTM_VDP_GFX_SetLayerAddrEX @0x805F4178`、
     `OPTM_VDP_GFX_GetLayerAddr @0x805F41D8` 同为 `add #0x6000; add #0x10; [..,r0,lsl#11]`。
   - recovery 3.10 (`TMP/recovery-deep/disasm-final.log:669`) `OPTM_VDP_GFX_SetLayerAddrEX
     @0xC032912C`：`add r3,r3,#0x6000; add r3,r3,#0x10; add r0,r3,r0,lsl#11`。
   - 社区 4.4.35_ecoo @`0xC06DB3BC`：`add r3,r3,#0x6000; ... add r3,r3,#0x10;
     strne r2,[r3,r0,lsl#11]`。
   `VO_base=0xf8cc0000` 由 `DISP_Init @0x805DB2D4` 的 `movw r0,#0; movt r0,#0xf8cc;
   bl DISP_HAL_Init` 经 ioremap（全 vmlinux 18 处 `movt #0xf8cc/#0xf8ce`），基址存进
   运行时全局指针（`0x81141c24`/`0x81138758`），故不作静态字面量出现。
4. **+0x494 在真实结构里根本不是 G0_ADDR**：逐字段查得 full-struct `+0x490=GP0_PARARD`、
   **`+0x494=GP1_PARARD`**（GP 图形处理层参数读寄存器），`+0x498=Reserved_12[0x28]`；
   `+0x49c`/`+0x4a0` 落在 `Reserved_12` 空洞内。GP0 系列在 `+0x9000`（`GP0_CTRL=+0x9000`、
   `GP0_IRESO=+0x900c`）。**[观察] legacy 驱动读 +0x494 实际读的是 GP1_PARARD，不是显存地址**，
   这解释了 `docs/050:925` 短接态 `VO G0_ADDR/STRIDE/IRESO (+494/+49c/+4a0)=0/0/0`
   ——那次探针用的是 A 组偏移，且 `/dev/mem` 外设区受 STRICT_DEVMEM 限制（docs/050:938）。

### D.2 定死结论（backport 驱动 / legacy 绿带判据应写哪组）

- **[观察·真值] GFX 图层寄存器（相对 `VO_base=0xf8cc0000`）**：
  `G0_CTRL=+0x6000`、`G0_UPD=+0x6004`、`G0_ADDR=+0x6010`、`G0_NADDR=+0x6018`、
  `G0_STRIDE=+0x601c`、`G0_IRESO=+0x6020`。**layer 偏移规则**：
  `addr(layer N) = VO_base + 0x6010 + (N << 11)`，`N*0x800 = CONFIG_HIFB_GFX_OFFSET`
  （`drv_hifb_config.h:67`，mv100 走 `#else` 分支 = 0x800；`lsl #11` 与 `str [..,r0,lsl#11]`
  反汇编逐字对应；`VDP_GFX_SetLayerAddr` 的 `lsl r0,#0xb; ... str [r1,r0,lsl#2]` 等价）。
- **[观察] ioremap 最小长度**：
  - SDK 用 `CONFIG_VDP_SIZE=0xfff0`（`drv_hifb_config.h:71`，
    `drv_hifb_adp.c:611 HI_GFX_REG_MAP(0xf8cc0000, 0xfff0)`）——映射整个 VDP 窗口。
  - 只读 **layer 0（G0）** 三寄存器：覆盖 `+0x6020` 即可 → 取整 **≥ 0x7000**
    （覆盖整个 `0x6000..0x6800` G0 块）。
  - 要写/读 **全部 6 个 GFX 层**（`OPTM_VDP_GFX_SetLayerAddrEX` 里 `cmp r0,#5`，layer 0..5）：
    `0x6010+5*0x800=0x8810`、`G0_IRESO(layer5)=0x8820` → **≥ 0x9000**。
  - **[推断] 建议 backport 直接用 0xfff0**（与 SDK 一致、最不易漏），最低 0x7000（只 G0）。
- **[观察·关键] `patches/kernel/hi3798mv100-hdmi-console.c` 现配置双重错误**：
  `:53 VO_REG_SIZE=0x1000` 只覆盖 `+0x000..+0xfff`，**完全够不到 +0x6010**；
  `:54-56` 用 A 组 +0x494/0x49c/0x4a0 读的是 GP1_PARARD/保留空洞。二者叠加
  → [推断] 驱动必然读不到有效显存（"读到 0"）。**legacy 绿带判据与 backport 驱动都应改用 B 组
  偏移并把 ioremap 扩到 ≥0x7000**（标 [推断]：真机寄存器确认前不改仓库文件）。
- **[未知] 真机寄存器确认尚缺**：全项目 docs/TMP 中**没有任何一次在正确偏移
  `0xf8cc0000+0x6010` 上的真机 MMIO 读值**（全网扫描 0x6010/0x6000 命中为空）；
  `docs/050` 的探针用的是 A 组 +0x494 且落在短接态/STRICT_DEVMEM 受限路径。
  因此 B 组"是硬件真值"由「SDK 结构体逐字段 + 三份真内核指令」双独立 oracle 坐实为
  [观察]（静态最强证据），但**"真机上该寄存器此刻等于哪个物理地址"仍是 [未知]**，
  需真机读 `0xf8cc6010` 并与 `HIFB_DispBuf_HD` 对比（见 UNKNOWNS 优先级 3）。

### D.3 `pdm_tag` 交接链与 `HIFB_DispBuf_HD=0x3f6ce000` 是否可用 handoff

- **[观察] 交接机制坐实（指令级）**：内核 `pdm_reserve_mem @0x80F0378C`：
  `movw r0,#0x214; movt r0,#0x80d0`（构造 `0x80d00214` = "pdm_tag" 串 VA）→
  `bl get_param_data("pdm_tag", buf, 0x200)` → `bl pdm_read_item` 逐个解析 →
  两次 `bl simple_strtoul(...,16)` 取 `<addr>,<len>` → `bl memblock_reserve(addr,len)`；
  `printk` 格式串 `pdm: name:%s, phyaddr:0x%08x, addrlen:0x%08x` 亦在 vmlinux 中。
  hiboot 侧（SDK 真源码 [观察]）：`reserve_mem.c:90-123` 从 DDR 顶动态分配，
  `drv_pdm.c:2294` `HI_DRV_PDM_AllocReserveMem(name,len,&phy)` 记入 `g_stResBuf[]`，
  `drv_pdm.c:2376-2410` `HI_DRV_PDM_SetTagData()` 序列化
  `version=1.0.0.3 <Name>=0x<PhyAddr>,0x<Len> ...` 并 `:2406 set_param_data("pdm_tag",...)`。
  **[推断] 地址按"名字"交接，是动态预留表，不是硬编码物理常量。**
- **[推断] `HIFB_DispBuf_HD = 0x3f6ce000` 是唯一有交接语义的候选**：来自
  `/proc/msp/pdm` Reserve Mem Info（`docs/041:70`，8,298,496 B ≈ 单帧 1920×1080×4
  =8,294,400 上取整），是 `pdm_tag` 里按名字 `HIFB_DispBuf_HD` 预留的 logo/显示缓冲，
  **即 hiboot logo 帧缓冲 handoff 的合理值**（对应 8 候选中的 A）。
- **[观察] 明确区别于 `0x3C55C000`**：后者是**社区 4.4 内核 hifb 自己**经
  `HI_DRV_MMZ_Map`（`hifb_buf_map @0x80602458`）运行时分配并 `register_framebuffer`
  注册的 `/dev/fb0 smem_start`（smem_len 0xFD2000 双缓冲，`fb-report-1`/`docs/021:16`，
  `docs/041:63-66` 已标 [推断] 不可直接抄）——**不是 hiboot 交接值**，是内核自有缓冲。
  `0x0fc54000` 又是短接态 recovery 3.10 内核自初始化 hifb 的 fb0（`docs/050:918`）。
  三值分属三条独立路径，互不等价。
- **[未知] "可用"仍需一项真机确认**：`0x3f6ce000` 是否**等于正常开机路径下 VO G0_ADDR
  (`0xf8cc6010`) 当前扫描的物理地址**、是否跨次稳定、双缓冲第二帧是否也落在该预留区——
  静态不能证（`docs/041:82` 自标"需真机确认"，`docs/048 §2` 把完整分配序列列为 [未知]）。
  **[推断] 对主线 simplefb**：候选用 **A=0x3f6ce000 + 1920×1080@7680 a8r8g8b8 + span
  覆盖双缓冲 0xFD2000 + DTB no-map**；**B=0x3C55C000 弃用**。但更稳是运行时解析
  `pdm_tag` 取 `HIFB_DispBuf_HD` 的 PhyAddr，或读 B 组偏移的 G0_ADDR 寄存器——
  且一切之前先确认"内核是否启动"（UNKNOWNS 优先级 0）。

