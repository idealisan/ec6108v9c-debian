# 原厂固件全量反汇编归档（EC6108V9C / Hi3798MV100）

> 2026-11-09 归档。目标：把可复用的反汇编结论、函数清单、调用图、引擎脚本纳入版本库，
> 供后续主线 6.x 内核 + 海思私有显示驱动 backport（`patches/vendor-display/`、docs/052）复用。
> 源产物位于 gitignored 的 `TMP/stock-rom-research/full-disasm/`；本目录是其**精选归档**。

## 这是什么

对原厂两个二进制做的**全量、逐字、不跳过**反汇编（REA 方法论，标注遵循 docs/033 §2）：
- `p01_fastboot.img`：1 MiB 裸 ARM，Fastboot 3.3.0 U 盘刷机分支 hiboot，load `0x00C00000`。
- `p11_vmlinux.bin`：3.10.0_s40 内核，LMA `0x80008000`，kallsyms 重建 62,959 实名符号。
- 交叉验证：recovery 3.10、社区 4.4.35_ecoo、HiSTB SDK `hi_reg_vdp.h` 全 struct。

标注纪律：**[观察]** = 指令/立即数/寄存器偏移/调用边；**[推断]** = 据观察推的功能；
**[未知]** = 静态不可定、需真机。禁止从字符串名/符号名反推行为。

## 先读这几个

| 文件 | 内容 |
|---|---|
| `FINDINGS.md` | 覆盖度台账 + 明确结论；**§D 一锤定音** VO GFX 层寄存器真实偏移 |
| `display_chain.md` | 逐函数显示链还原（DISP_Init → VO G0 → HDMI TX/PHY → hifb fb0 → pdm_tag） |
| `UNKNOWNS.md` | 全部未决项，按优先级；**优先级 0 = 6.x 内核到底起没起**（先于显存地址） |
| `MANIFEST.md` | 目标二进制清单（sha256/加载地址）、工具、复现命令 |

### 决定性结论（[观察]，三内核反汇编 + SDK 全 struct 双 oracle）
- **VO GFX 层 0 显存地址寄存器 = `0xf8cc0000 + 0x6010 + (layer<<11)`**，
  `G0_CTRL=+0x6000 / G0_ADDR=+0x6010 / G0_STRIDE=+0x601c / G0_IRESO=+0x6020`。
- **docs/023 §4.2 的 `+0x494` 系列是"删掉 `Reserved_57[1840]` 等保留空洞后的 605 u32 压缩视图"计算错误**，
  不是另一套硬件窗口；full-struct 下 `+0x494` 实为 `GP1_PARARD`。三份真内核
  `VDP_GFX_SetLayerAddr` 一致为 `add #0x6000; add #0x10; str/ldr [.., lsl#11]`。
- **ioremap**：只读 layer0 需 ≥`0x7000`，全部 6 层 ≥`0x9000`，SDK 值 `CONFIG_VDP_SIZE=0xfff0`。
- legacy `patches/kernel/hi3798mv100-hdmi-console.c` 用 `+0x494` 且 `VO_REG_SIZE=0x1000`，
  [推断] 既读错寄存器又够不到真值——是运行时"读到 0"的静态可解释嫌疑（真机待确认，未改仓库文件）。
- **交接 = `pdm_tag` 具名预留表**（`HIFB_DispBuf_HD`），地址动态、按名字交接、非硬编码。
  `0x3f6ce000`(预留) / `0x3C55C000`(社区内核自有 fb0) / `0x0fc54000`(短接 recovery 自有 fb0) 三者互异、不同路径。
- **p01 stock hiboot 不含显示实现**（0 个 VO/HDMI 基址字面量、0 个显示名代码 xref）；
  带显示入口的是社区 `fastboot.bin`（另一 build）。内核侧私有栈才是显示实现所在。
- **静态反汇编不能判定"6.x 内核是否启动失败"**——需真机信号（绿带/pstore/IP）。

## 文件清单（本目录）

| 文件 | 规模 | 内容 |
|---|---|---|
| `FINDINGS.md` | 22K | 覆盖度台账 + 6 个明确回答 + §D 偏移定音 |
| `display_chain.md` | 15K | 逐函数显示链（指令级） |
| `UNKNOWNS.md` | 8.4K | 未决项（优先级 0..7） |
| `MANIFEST.md` | 8.6K | 二进制清单/工具/复现命令 |
| `functions_p01.tsv` | 145K | p01 全函数清单（2054 行） |
| `functions_p11.tsv` | 3.2M | p11 实名函数清单（62135 行） |
| `calls_p01.tsv` | 268K | p01 全量 BL/B 调用边（8340 行） |
| `display_funcs_p01.txt` | 113K | p01 中 50 个 MMIO 候选函数逐个反汇编 |
| `display_funcs_p11.txt` | 4.4M | p11 中 1420 个显示函数逐个全函数反汇编 |
| `analysis_p01.json` | 123K | p01 机器可读覆盖度/调用/字面量 ledger |
| `ledger.json` | 38K | 两目标 + boot.img 总 ledger |
| `reg_init_sequence.md` | 13K | **点亮 HDMI 的逐寄存器初始化序列**（backport 可落地表，§2 最小清单） |
| `reg_init_sequence.tsv` | 11K | 上表机器可读版（81 行 / 12 列） |
| `annotate.py` | 4.2K | 可复现注解器（kallsyms 实名 + BL/literal/movw-movt 解析） |
| `engine_p01.py` / `engine_full.py` | 13K+13K | 可复现分析脚本（capstone 5.0.7 / python3） |

### 私有驱动最硬的可用成果（[观察]，双内核 oracle 交叉）
`reg_init_sequence.md` 给出可直接写成 `writel` 表的确定性静态序列：
- **HDMI PHY 7 次写**（`SI_TX_PHY_INIT`，物理 `0xf8ce1800+4*reg`），顺序：
  reg0=0x00 / reg2=0x02 / reg3=0x02 / reg4=0x09 / **reg5=0x04** / reg6=0x00 / reg1=0x01(最后上电)。
  docs/035（recovery 3.10, radare2+capstone）表 A 给出**完全相同的 7 组**——两份内核两套工具互证。
  **[观察·偏差]** SDK `phy.c` mv100 分支 reg5 写 `0x01`，两份真内核二进制都写 `0x04`；
  按"逐字节来自原厂资产 + 以反汇编为准"，backport 取 **0x04**（SDK=0x01 作溯源注释）。
- **CRG 复位序列**（`SI_HW_ResetHDMITX`，`0xf8a22000`）：+0x10c=0x23f → +0x110=0x10 →
  Delay → +0x110=0x01 → Delay → `SI_TX_PHY_INIT` → Delay → +0x10c=0x3f → Delay(10) →
  `WriteByte_8BA(0x72,0x7b,2)` → DDC speed。
- **基址图**：VO `0xf8cc0000`、HDMI TX SLV0 `0xf8ce0000`/SLV1 `0xf8ce0400`/CEC `0xf8ce0800`、
  PHY `0xf8ce1800`、CRG `0xf8a22000`；虚拟 = 物理 + `0x05000000`。
- **[推断] 条件编译陷阱**：SDK `hdmi.c:358` HW/SW reset 被 `#if !(mv100...)` 排除、`hdmi.c:392-418`
  绝对地址组在 `#if 0` 死代码内——别照抄；活动 mv100 路径见 `reg_init_sequence.md §1 序列C`。
- **诚实边界**：RMW 值一律 [推断]、fb_base/EDID/HPD/时序运行时定 [未知]、
  驱动读哪个窗口的真机 MMIO 确认未做、"内核是否启动"仍是 UNKNOWNS 优先级 0。

### 未纳入本归档的两个超大逐字 dump
`disasm_p01.txt`（22 MB，262,144 行 = 1 MiB 全字）与 `disasm_p11.txt`（314 MB，
3,979,360 行 = code span 全字）是**逐字全覆盖证据**。它们体积过大不宜入库，
且可由 `engine_*.py` + 原厂镜像完全复现（脚本用 `HERE`/相对路径定位输入，
见 `MANIFEST.md §2/§3`）。需要核对某条指令时，在 `TMP/stock-rom-research/full-disasm/`
本地重跑引擎或查已有 dump 即可；本归档的函数清单/调用图/显示函数反汇编已覆盖复用所需。

## 合规
- 只读逆向产物，未刷机、未连设备、未触发 CI、未装软件、未改任何仓库源码（归档除外）。
- 不含本机绝对路径 / 用户名 / IP / 凭据。
- 原始固件镜像（`backup_stock/` 等）为本地资产，gitignored，未入库。
