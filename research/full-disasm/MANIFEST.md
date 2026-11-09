# MANIFEST.md — 全量逐函数反汇编工程：目标二进制、加载地址、工具、命令

> 本目录所有内容为**只读逆向产物**，写入位置仅 `TMP/stock-rom-research/full-disasm/`
> （gitignored）。未改任何仓库文件、未刷机、未连设备、未触发 CI、未安装软件。
> 编译者标注遵循 `docs/033 §2`：指令/立即数/寄存器偏移/调用边 = [观察]；功能推断 = [推断]；
> 静态无法定、需真机 = [未知]。禁止从字符串名/符号名反推行为。

## 1. 目标二进制清单（sha256 / 大小 / 架构 / 加载地址 / 入口）

| # | 文件（相对仓库根） | sha256(前16) | 大小 | 类型/架构 | 加载地址(VA) | 入口 |
|---|---|---|---|---|---|---|
| A | `TMP/stock-rom-research/extracted/p01_fastboot.img` | `bac0be9ff5926de1…` | 1,048,576 B | 裸 ARM LE / Fastboot 3.3.0 U-Boot | **[观察] 0x00C00000** | [观察] reset 向量 `b` → 文件 0x206c / VA 0x00C0206C |
| B | `TMP/stock-rom-research/extracted/p11_kernel.bin` | `b0662e56ec1f1a19…` | 7,898,576 B | uImage(magic 0x27051956), comp=none, name=`Linux-3.10.0_s40` | uImage load=entry=0x02000000 | 同左 |
| B′ | `TMP/stock-rom-research/extracted/p11_vmlinux.bin` | `d43d57f4be2d7abb…` | 17,432,904 B | B 的 zImage piggy gzip 解压结果（**逐字节相等，[观察]**） | **[观察] 内核 LMA 0x80008000** | [观察] `_stext`=0x800081C0 |
| C | `TMP/stock-rom-research/extracted/p11_kernel.img` | — | 12,582,912 B | Android boot.img(`ANDROID!` @0) 包装 B | kernel_addr=0x03E08000, ramdisk_addr=0x04E00000, tags_addr=0x03E00100, page_size=2048 | — |
| D | `TMP/stock-rom-research/extracted/p03_recovery.img` | — | 16,777,216 B | Android boot.img(`ANDROID!` @0x800000), kernel 2,563,176 B | kernel_addr=0x03E08000 | — |
| E | `TMP/stock-rom-research/extracted/p03__sbin__recovery` | `d4545cdb93b38e66…` | 445,036 B | ARM ELF32 (LE) recovery UI，走 `FBIOGET_*` blit，不碰寄存器 | 动态链接 ELF | — |
| F | `TMP/stock-rom-research/extracted/p05_baseparam.img` | `819fccdde59672a8…` | 4,194,304 B | `BASE_TABLE_DISP` 参数表（数据） | — | — |
| G | `TMP/stock-rom-research/extracted/p08_fastplay.img` | — | 16,777,216 B | fastplay 分区（**辅助核查：0 显示符号/0 MMIO 常量**） | — | — |
| H | `TMP/community-restore/fastboot.bin` | `fd5b4ac6ce4d…` | 539,264 B | 社区 U 盘顶层 fastboot（**辅助对照 build**） | — | — |
| I | `TMP/community-restore/mv100/hi_kernel.bin` | — | 10,862,647 B | 社区 4.4.35_ecoo uImage（**辅助对照内核**） | 0x02000000 | — |

### 加载地址判定证据（[观察]，均出自反汇编/字节，非字符串名）
- **A = 0x00C00000**：文件 `0x2044` 字面量 `0x00C00040`、`0x204c` = `0x00C00000`（U-Boot
  重定位 `__image_copy_start`/`__rel_dyn_start` 对）；异常向量表 `0x20..0x38` 的 7 个
  `ldr pc,[pc,#0x14]` 目标 = `0x00C04E80..0x00C05180`，且文件 `0x4E80` 处反汇编确为
  ARM 异常处理桩（`ldr sp,[pc,#-0x28]; mrs lr,spsr; movs pc,lr`）——基址与文件偏移一一对应。
  `0x00C00000 + 文件偏移` 的字面量簇（0x00c8xxxx 共 3643 个）落在 0x7A000..0x93000 字符串池。
- **B′ = 0x80008000**：kallsyms 重建后 `_stext`=0x800081C0、`linux_banner`=0x80B3E010，
  且 `linux_banner` 字符串文件偏移 0xB36010 → `0x80008000 + 0xB36010 = 0x80B3E010` 完全吻合；
  `__kstrtab` 80/80 oracle 通过（base=0x80008000, DELTA=0）。**注意：与 recovery 内核
  (0xC0008000) 不同，本正常开机内核链接在 0x8000xxxx**。
- **B 的 uImage**：`load=ep=0x02000000`、comp=none（即 zImage 自带解压）、name=`Linux-3.10.0_s40`；
  gzip piggy 在 payload+0x5894，解压 17,432,904 B = B′（ha 一致）。

## 2. 工具与命令（本机已确认可用，未安装任何东西）

| 工具 | 版本 | 用途 | 命令形态 |
|---|---|---|---|
| capstone | 5.0.7 | **主力：全量线性 sweep** | `Cs(CS_ARCH_ARM, CS_MODE_ARM\|CS_MODE_LITTLE_ENDIAN)`，`detail=True, skipdata=True`；逐 4 字节 `md.disasm(word, VA, count=1)` |
| radare2 | 6.2.4 | 交叉验证（已定位函数 `pd`/`axt`） | `/opt/homebrew/bin/r2 -2 -q -a arm -b 32 -m 0x00c00000 -c 'pd N @ VA' file` |
| objdump | Apple LLVM 21 | **不可用**：LLVM objdump 不支持 `-b binary`（实测 `error: unknown argument '-b'`），故 raw vmlinux 全量反汇编由 capstone 承担 | — |
| python3 | — | kallsyms 重建、函数清单、ledger | `engine_full.py` |

- `r2 -A ... p01_fastboot.img`（裸 blob，aaa）→ **识别 0 个函数**（team-lead 冒烟结论复现），
  因此 **不把 r2 `afl` 当全量依据**；全量覆盖度以 capstone 线性 sweep 为准。
- `r2 aaa` 在 17MB vmlinux 上 `timeout 120` 超时无输出，同样不作为函数边界依据。

## 3. 覆盖度定义与引擎

- **A（p01）**：capstone 对 `0x0..0x100000` **全部 262,144 个 4 字节字**做线性 sweep，
  逐条写入 `disasm_p01.txt`（"逐条指令，不挑不跳"）。CODE 块出指令；STR/FILL/DATA 块
  按规则以 `.word 0xXXXXXXXX ; <type> (data, not code)` 形式**照样逐字列出**（不是静默跳过），
  并在文件头把所有非 CODE 区间作为 `SKIPCODE` 显式登记。
  数据/代码按 4KiB 块启发式分类（0xFF/0x00 占比>0.5→FILL，可打印占比>0.75→STR，否则 CODE），
  分类规则与结果都在 `engine_full.py` / `ledger.json` 可核对。
- **B′（p11）**：kallsyms 重建 `_stext.._einittext`（文件 0x1C0..0xF2E340），对该 code span
  **全部 3,979,360 个 4 字节字**做线性 sweep 写入 `disasm_p11.txt`；code span 之外的
  头部/数据/kallsyms-table/符号名区在文件头以 `OUTSIDE` 区间显式登记（等价于 objdump -d
  只排 .text 的语义）。函数清单由 kallsyms 62,959 符号给出（非 r2 猜测）。

## 4. 产物文件（本目录）

| 文件 | 内容 | 规模 |
|---|---|---|
| `MANIFEST.md` | 本文件 | — |
| `functions_p01.tsv` | p01 完整函数清单（2054 行）：VA/size/name/显示候选/分析状态/入口证据 | 148 KB |
| `functions_p11.tsv` | p11 完整函数清单（62,135 行，kallsyms 实名）：VA/size/type/name/is_display/analyzed | 3.4 MB |
| `disasm_p01.txt` | p01 全量线性 sweep（**262,144 行 = 全部字**） | 23 MB |
| `disasm_p11.txt` | p11 code span 全量线性 sweep（3,979,360 行） | 315 MB |
| `display_funcs_p01.txt` | p01 中 50 个含 MMIO 字面量的函数逐个反汇编 | 115 KB |
| `display_funcs_p11.txt` | p11 中 1,420 个显示相关实名函数逐个反汇编（含字面量池） | 4.6 MB |
| `calls_p01.tsv` | p01 全量 BL/B 调用边（8340 行） | 275 KB |
| `analysis_p01.json` | p01 机器可读覆盖度/调用/字面量 ledger | 126 KB |
| `ledger.json` | 两目标 + boot.img 总 ledger | 39 KB |
| `display_chain.md` | 逐函数显示链还原（执行顺序：指令→调用→数据来源→标注） | — |
| `FINDINGS.md` | finding ledger + 6 个明确回答（含"内核是否启动"） | — |
| `UNKNOWNS.md` | 全部未决项（含优先级排序） | — |
| `engine_p01.py` / `engine_full.py` | 可复现分析脚本 | — |

## 5. 交叉验证（独立 oracle，避免单点误判）

1. **kallsyms 独立 oracle**：`__kstrtab_*` 符号地址指向的字符串 80/80 与符号名一致
   （base=0x80008000, DELTA=0）——证明符号表地址对齐正确，函数名可实名而非 `sub_XXXX`。
2. **三份内核交叉验证 G0 图层 ADDR 偏移**：正常开机 3.10 (B′)、recovery 3.10
   (`TMP/recovery-deep/recovery-vmlinux.bin`)、社区 4.4.35_ecoo (`/tmp/comm_vmlinux.bin`)
   的 `VDP_GFX_SetLayerAddr` / `OPTM_VDP_GFX_SetLayerAddrEX` / `OPTM_VDP_GFX_GetLayerAddr`
   反汇编**一致**为 `VO_base + 0x6000 + 0x10 + (layer<<11)` = **+0x6010**（见 display_chain.md）。
3. **SDK 源码交叉**：`TMP/sdk-src/source/common/drv/include/hi3798mv100/hi_reg_vdp.h`
   的 `S_VDP_REGS_TYPE` 含 `Reserved_57[1840]`，按 4 字节/成员计算 G0_CTRL=+0x6000、
   G0_ADDR=+0x6010、G0_STRIDE=+0x601C、G0_IRESO=+0x6020——与反汇编的 `add #0x6000; add #0x10` 吻合。
   `drv_hifb_config.h:67` (`#else` 分支, mv100) `CONFIG_HIFB_GFX_OFFSET=0x800` 与 `(layer<<11)` 吻合。
4. **四份 fastboot 对照**（p01 / p01_gz / 社区顶层 / 社区 mv100）：均 **0 个**
   `0xf8cc0000`/`0xf8ce0000`/`0xf8ce1800` 字面量；仅 `0xf8a22000`(CRG) 13~14 个。
   内核则通过 `DISP_Init` 的 `movw r0,#0; movt r0,#0xf8cc; bl DISP_HAL_Init` 构造 VO 基址
   （18 处 `movt #0xf8cc/#0xf8ce`），说明**寄存器基址在运行时由 ioremap 全局指针给出，
   不是静态字面量**——这是"为什么字面量扫描扫不到显示常量"的根因，也解释了为何必须用
   movw/movt 构造分析而不能只看字面量池。
