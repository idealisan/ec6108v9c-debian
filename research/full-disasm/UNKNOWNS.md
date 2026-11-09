# UNKNOWNS.md — 全部未决项（逐条：结论 + 证据 + 需什么真机动作）

> 按优先级排序。**第 0 项（内核是否启动）优先于所有显存地址问题**——给没启动的内核调
> fb_base 是方向性错误（team-lead 补充判断，docs/044:14-15）。
> 标注：[观察]=反汇编/字节事实；[推断]=据此推的功能；[未知]=静态不可定。

---

## 【优先级 0】主线 6.x 内核到底有没有启动到 userspace？
- **结论（[未知]）**：静态反汇编**不能判定**。全量反汇编只覆盖"若执行会做什么"，
  产不出"是否真的执行到"。docs/044 的「没启动到 userspace」是配置层排除法推断
  （[推断]），不是反汇编证据。
- **证据**：本工程全量反汇编（`disasm_p11.txt` 是原厂 3.10 内核，**不是**我们的 6.x）；
  无 IP + 无显示同时出现（docs/044:14-15、docs/026 §0、docs/024 §6）。
- **需什么真机动作才能定**（本机无串口，docs/006/013）：
  1. 刷 6.x 包上电，看**绿带启动标记**（顶部 240 行纯绿，`docs/024 §6.1`）：
     出现=内核跑到 `subsys_initcall`；仍是 `Debian Linux` logo=内核没跑到该 initcall。
  2. 重启进社区系统读 **`/sys/fs/pstore/dmesg-*` / `console-*`**，找 6.x 内核早期
     `printk` / `hi3798-fb: VO layer0: addr=...`：有=内核起来了。
  3. **路由器新 IP / SSH**：有=内核+rootfs+userspace 全通。
  4. 按 `docs/026:86-93` 判 A(内核没起)/B(起到驱动但显示未绑)/C(全通)。
- **若三项全无**：先查优先级 1 的装载地址/DTB/ATAG 交接，暂停 fb_base 候选逐个试。

## 【优先级 1】6.x 的 appended-DTB + 无 ATAG 交接，与原厂 3.10 启动约定是否冲突？
- **结论（[推断]/[未知]）**：静态只能列"约定不同点"，不能证明哪条导致极早期挂。
- **证据（[观察]）**：原厂 boot.img `kernel_addr=0x03E08000`、ATAG tags=0x03E00100、
  vmlinux LMA=0x80008000、`mem=`/`mmz=` 由 env 合并；6.x uImage load=ep=0x02000000、
  `mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0`、appended DTB `/chosen/bootargs`
  + `/memory@0`、无 `mmz=`。内核 LMA（0x80008000 vs 0xC0008000 系）、参数通道
  （ATAG vs DTB cmdline 覆盖 docs/018:119-123）、DTB append 位置/totalsize 是嫌疑点。
- **需什么真机动作**：优先 0 的绿带/pstore 日志；若能拿到早期 `printk`，看是否到
  `setup_machine_fdt`/`memblock` 之前就停；核对 uImage load 与 hiboot `bootm` 装载目标
  是否一致、DTB 是否被正确 append 且 totalsize 合法。

## 【优先级 2】hiboot 交接显存的**确切物理地址**与跨次稳定性
- **结论（[未知]）**：地址是 `reserve_mem_alloc` 动态分配（`reserve_mem.c:90-123`，
  mem=1G→顶 0x3FFFE000 向下，[推断]），由 `pdm_tag` 具名表交接；给定固定 mem= +
  固定分配序列时确定，但**静态不能精确复现绝对地址**，也不能证明跨次/跨路径稳定。
- **证据**：`drv_pdm.c:2376-2410` `SetTagData`、内核 `pdm_reserve_mem` @0x80F0378C 反汇编；
  docs/048 §2 列"到达 HI_GFX_ShowLogo 前的完整分配序列/各块 size"为 [未知]；
  docs/040(0x3C55C000) 与 docs/043(0x3f6ce000) 两实测值已不相等。
- **需什么真机动作**：在**正常开机路径**在线态读 `/proc/msp/pdm` Reserve Mem Info
  （拿 `HIFB_DispBuf_HD` 当次实际 PhyAddr/Len），**重启 2~3 次对比是否恒定**；
  并读 `pdm_tag` 原始字符串核对名字→地址映射。

## 【优先级 3】VO G0 图层 ADDR 寄存器的**真机读值**（偏移本身已在 FINDINGS §D 定死）
- **结论（偏移已定 [观察]；真机读值仍 [未知]）**：FINDINGS.md §D 已用「SDK 结构体逐字段
  + 三份真内核 `add #0x6000; add #0x10; str/ldr [..,r0,lsl#11]`」双独立 oracle 定死真值 =
  `VO_base(0xf8cc0000)+0x6010`（`G0_CTRL=+0x6000/G0_ADDR=+0x6010/G0_STRIDE=+0x601c/
  G0_IRESO=+0x6020`、layer*0x800、ioremap≥0x7000/建议0xfff0）。
  **+0x494 系列已确证是"删掉 `Reserved_*` 空洞后的压缩视图"计算错误**（compact=605 u32=
  0x974 B，与 docs/023 §4.2:107 自述逐字吻合；full-struct +0x494 实为 `GP1_PARARD`，
  不是 G0_ADDR）——不再是"两个窗口"的开放问题，`patches/vendor-display/PORTING.md:18,22-27`
  已据此可定稿。
- **仍需真机确认的只剩一件事**：全网 docs/TMP **没有任何一次在 `0xf8cc0000+0x6010`
  上的真机 MMIO 读值**（`docs/050:925` 用的是 +0x494 且短接态/STRICT_DEVMEM 受限）。
- **需什么真机动作**：正常开机在线态，用可读 MMIO 的手段（社区内核 `/dev/mem` 对外设区
  Bus error，fb-report-1 §7 已证）读 `0xf8cc6010`，与同次 `pdm_tag` 里
  `HIFB_DispBuf_HD` 的 PhyAddr 对比；确认该寄存器此刻确为有效 DDR 地址且跨次稳定。
  驱动侧据此把 `hi3798mv100-hdmi-console.c` 的 +0x494/0x1000 改成 +0x6010/≥0x7000。

## 【优先级 4】`0x3f6ce000` 是否就是 VO 当前扫描的那块（能否直接当 fb_base）
- **结论（[推断]/[未知]）**：`0x3f6ce000` = `/proc/msp/pdm` 的 `HIFB_DispBuf_HD`
  （≈单帧 1920×1080×4，docs/041:80-83 自标"很可能是 VO 实际扫描缓冲，需真机确认"）。
  它与 `0x3C55C000`(内核 fb0 mmap 基址) 是**两块不同的缓冲**。
- **证据**：docs/041 §1.2 `/proc/msp/pdm` Reserve Mem Info；本轮 hifb_buf_map→
  `HI_DRV_MMZ_Map` 反汇编（fb0 来自 MMZ 运行时映射）。
- **需什么真机动作**：在线态把 `HIFB_DispBuf_HD` 物理地址与 VO G0_ADDR 寄存器值
  对比；并确认双缓冲两帧是否都落在该预留区（写满两帧才不闪，docs/040）。

## 【优先级 5】正常开机路径下 hiboot 显示实现的载体是哪个二进制
- **结论（[推断]）**：本 p01（U-disk 刷机分支 build）无显示实现（0 MMIO + 0 显示名
  xref）；带 `HI_GFX_ShowLogo`/`0xf9000000` 的是**社区 fastboot.bin**（另一 build），
  或运行期 fastapp/fastplay 模块（docs/045 §1.6；p08_fastplay 本轮扫 0 显示符号，
  故 fastplay 分区本身不含）。
- **证据**：display_chain.md §0；四份 fastboot 交叉扫描；p08_fastplay 16MB 全扫。
- **需什么真机动作**：确认正常开机时执行的是 p1 里哪份 fastboot、是否从 eMMC 另一
  区域/内存加载了带显示代码的模块；对该二进制再做同样的全量反汇编（本轮未把它列为
  主目标，故其显示链函数体未逐字节落表）。

## 【优先级 6】HDMI TX/PHY 逐寄存器写入序列、EDID/HPD 时序
- **结论（[未知]）**：内核侧 `HI_DRV_HDMI_Init`/`SI_TX_PHY_INIT` 等函数体已在
  `display_funcs_p11.txt` 全量给出，但**未逐字节列成"寄存器物理地址+偏移+立即数"表**，
  也未与 SDK `source/boot/product/driver/hdmi/hdmi_1_4/` 逐条对齐。
- **需什么真机动作/后续静态**：若确需从零点亮 HDMI 的路径，对 `SI_TX_PHY_INIT`
  及 `hdmi_Disp2EncFmt`/`TX_PHY_WriteRegister` 逐个补基本块级寄存器写表；EDID 值
  需真机 HDMI sink 在线读。

## 【优先级 7】`reserve_mem` 完整分配序列、DDR 顶端 Linux 视角物理基址
- **结论（[未知]）**：docs/048 §2 已列此二者为 [未知]；`hi_common.h:14 MEM_BASE
  (0x80000000)` 与实测 0x3C55C000/0x3f6ce000 量级不符，疑有高位映射/别名。
- **需什么真机动作**：在线态读 `/proc/iomem`、`/proc/msp/pdm` 全表，
  对照 `reserve_mem` 算法逐块复现。

---

## 覆盖度诚实声明（不假装全查完）
- p01：262,144 字**全量逐字反汇编**、2,054 函数全有条目；50 个 MMIO 候选逐个反汇编。
  但**除显示链外的 2,004 个函数未逐基本块精读**（全量反汇编已给出）。
- p11：3,979,360 行 code span **全量线性 sweep**、62,135 实名函数清单、
  1,420 显示相关函数逐个全函数反汇编；显示链关键函数逐条指令精读。
  **但 6 万余函数中绝大多数未逐基本块人工精读**——这是"全量反汇编 + 显示链定向精读"，
  不是"逐个人工读完 6 万函数"。
- 主目标 p01 内**确证没有**显示链函数体，故"hiboot 逐函数走通显示链"在本镜像内
  无法完成（不是遗漏，是确证不存在）；已改从内核侧 + SDK 真源码还原（display_chain.md §2）。
- 所有产物只读、写入仅 `TMP/stock-rom-research/full-disasm/`；仓库工作区未改动
  （`git status` 的两条遗留项 `scripts/qemu-boot-test.sh`/submodule 为既存、非本轮产生）。
