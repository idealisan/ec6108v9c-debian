# 034 — recovery vmlinux 显示初始化代码实证（radare2 + capstone 交叉验证）

> 2026-11-08。承接 `docs/031`（hiboot 反汇编的**负结果**）与 `docs/032`（recovery 第一突破口计划）。
> 目标：把 `docs/031 §7.1` 建议的「反汇编内核 vmlinux 提取显示初始化」真正做起来，
> 用 `docs/033` 引入的 REA 证据链规范记录：哪些是**观察**、哪些是**推断**、哪些仍是**未知**。
>
> - 方法：只读静态反汇编 + 常量 / 字符串 / `ldr-literal` 全量交叉引用扫描。
>   不刷机、不改真机、不构建镜像、不删文件、不访问项目外目录。
> - 对象：`TMP/recovery-deep/recovery-vmlinux.bin`（8,227,512 B，
>   SHA-256 `d91d91049db9893c5a5811826b73a79e58f82330a669729bee58713706ac6e7d`，
>   由 `TMP/rec-zImage` 的 xz piggy @`0x391f` 解出，见 `docs/032 §6`）。
> - 链接地址：**`0xC0008000`**（`PAGE_OFFSET=0xC0000000` + `TEXT_OFFSET=0x8000`），
>   已由 `stext` 入口反汇编自洽验证（`docs/033 §4`）。所有地址均为运行时 VA。

---

## 0. 结论先行（三分法）

| 级别 | 结论 |
|---|---|
| **[观察]** | recovery 内核里**存在真实、可达的显示初始化代码**：`DISP_Init` 入口把 VO 基址 `0xf8cc0000` 作为参数传入，随后调用 `DISP_HAL_Init` / `DISP_DA_Init` / `DISP_INTF` 链；`/proc/msp/hdmi0` 的 help 函数引用 `0xf8ce0000`。这与 `docs/031` 在 hiboot 里「只有字符串、代码不可达」形成对照。 |
| **[观察]** | 全文件 ARM `ldr-literal` 扫描 **2,056,878 条指令，3 个命中**加载 MMIO 基址常量；radare2 与 capstone 反汇编结果逐条一致（独立 oracle）。 |
| **[推断]** | 显示驱动**用 ioremap 得到的虚拟地址 + 全局结构体间接访问**寄存器：`0xf8cc0000 + 0x5000000` 存入 `0xc084c870+0x258`，再分配 `VDP_RegBackBuff`。因此基址常量只出现 1–2 次、不直接邻接 `str [rX,#off]` MMIO 写入。 |
| **[未知]** | **精确寄存器写入序列（基址+偏移+值+顺序）仍未取得**。需追 `0xc084c870+0x258` 字段被谁读取、以何偏移 `str`。本文不编造寄存器值。 |
| **[存疑]** | 这份 3.10 SDK 内核里 `0xf8ce0000` 被代码实际引用，而 `0x08ce0000` 0 命中，与 `docs/029`「`0xf8ce0000` 属 hi3716cv200、mv100 为 `0x8ce0000`」存在张力。**不据此推翻 `docs/029`**（可能是 SDK 多 chip 条件编译、HDMI 输入/RX 侧、或该内核针对不同 SoC 变体）——`docs/027 §6` 正因同类推断被撤销，不重蹈。 |

---

## 1. 工具链落地（用户已授权）

| 工具 | 版本 | 用途 | 获取方式 |
|---|---|---|---|
| radare2 | 6.2.4 | raw ARM 反汇编、独立 oracle | `brew install radare2` |
| capstone | 5.0.7 | Python 全量 `ldr-literal` 扫描 | 本机原有 |
| Node.js | **v26.12.1** / npm 11.20.0 | 满足 REA 门槛（≥26.12.1） | `brew install node`（`docs/033 §3` 记录的 `22.23.1` 已升级） |

记录两点环境事实（不隐瞒）：
- `brew install node` 首次因 `ca-certificates` 链接冲突中断，并顺带把 `simdutf` 从 9.0.0（`.34`）升到 9.3.2（`.37`），一度使旧 `node@22` 找不到 dylib；重试后 node 26.12.1 装成，`/opt/homebrew/bin/node` 指向它，旧版 symlink 由 brew 自行解链。当前 `node --version` / `npm --version` 均正常。
- brew 输出 `unknown install step: remove`（其非 Tier 1 配置的已知告警）与 `Unlinking node@22 ... symlinks removed` 均为 brew 自身行为，不影响结果。

**未安装 / 未注册**：Ghidra、IDA、Hopper、Kuna、binwalk、unblob 仍无；未运行 `npx rea-agents setup`，未改项目外的 agent 配置，未装 Java。理由见 `docs/033 §3 §7`：radare2 + capstone 已覆盖当前对象所需的反汇编能力，Ghidra 重且 MCP 配置复杂，不为「用 REA」而装。REA 的价值在本课题仍是**方法论**（`docs/033`），实际反汇编器如实标注为 radare2 / capstone。

---

## 2. 常量与字符串交叉引用扫描（观察）

### 2.1 MMIO 基址 4 字节小端字面量

| 常量 | 文件内 literal 数 | 偏移（首几个） | 指向该 VA 的 4B 指针数 |
|---|---|---|---|
| `0xf8cc0000`（VO/VDP） | 2 | `0x2c0570`, `0x31026c` | 0 |
| `0xf8ce0000`（HDMI TX） | 1 | `0x2da3d4` | 0 |
| `0xf9000000`（VO/VDP 备用区） | 40 | `0x5f64`, `0x384159`, `0x386029`, … | 0 |
| `0x08ce0000`（mv100 DT reg，`docs/029`） | **0** | — | 0 |

「指针数 0」≠ 无引用：ARM 通过 `ldr rX,[pc,#imm]` 从字面量池加载，不用绝对指针。故改用 §2.3 的指令级扫描。

### 2.2 显示字符串 VA 与指针引用

| 字符串 | VA | 指向该 VA 的指针数 |
|---|---|---|
| `DRV_HDMI_Read_EDID` | `0xc03d975c` | 2（`0x2db66c`, `0x3eed3c`） |
| `SI_ReadEDID` | `0xc03d9fe8` | 2（`0x2e0e24`, `0x3eedc0`） |
| `HI_DRV_DISP_Init` | `0xc03dde6c` | 2（`0x2fc514`, `0x3eeed4`） |
| `HI_DRV_HDMI_Init` | `0xc077209c` | 0 |
| `HDMI_Display` | `0xc077228c` | 0 |
| `register_framebuffer` | `0xc04c6403` | 0 |
| `HDMI_TX_PHY_BASE_ADDR` | 未找到 | — |

`HI_DRV_DISP_Init` / `DRV_HDMI_Read_EDID` / `SI_ReadEDID` 有指针引用（疑似符号/导出表或日志表），
而 `HI_DRV_HDMI_Init` / `HDMI_Display` / `register_framebuffer` 0 指针——符合 `docs/033 §4` 判断：
后者多为 `__func__` / printk 文本，经 PC 相对加载，**不能靠字符串地址定位函数地址**。

### 2.3 全文件 `ldr-literal` 扫描（关键实证）

capstone `skipdata=True` 全量反汇编 8,227,512 B 共 **2,056,878 条指令**，
对每条 `ldr rX,[pc,#imm]` 计算目标 VA 并回读该 word，命中 MMIO 常量者：

| 指令地址 | 加载到的常量 | radare2 反汇编确认 |
|---|---|---|
| `0xc02c8558` | `0xf8cc0000` | `ldr r3,[0xc02c8570] ; =0xf8cc0000` 后 `cmp r0,r3` → 地址区间判定 |
| `0xc02e21a0` | `0xf8ce0000` | `ldr r2,[0xc02e23d4] ; =0xf8ce0000`，位于 `/proc/msp/hdmi0` help 打印函数 |
| `0xc03180c0` | `0xf8cc0000` | `ldr r0,[0xc031826c] ; =0xf8cc0000` 后 `bl 0xc02f02cc` → **`DISP_Init`** |

radare2 独立反汇编三处，与 capstone 逐条一致（`docs/033 §2` 第 7 条要求的独立 oracle）。

---

## 3. `DISP_Init` 调用链反汇编（观察 + 推断）

### 3.1 入口 `0xc03180c0`（radare2）

```asm
0xc03180c0  ldr r0, [0xc031826c]   ; = 0xf8cc0000  (VO/VDP 物理基址)
0xc03180c4  bl  0xc02f02cc          ; 传入基址
0xc03180c8  subs r4, r0, 0
0xc03180cc  beq 0xc03180ec
0xc03180d0  ldr r3, [..]            ; "DISP_HAL_Init failed!"
0xc03180dc  ldr r2, [..]            ; "DISP_Init"
...
0xc03180ec  bl  0xc02edef8          ; DISP_INTF 相关
0xc03180f0  bl  0xc02ede18
0xc03180fc  bl  0xc02eceb8          ; "DISP_DA_Init failed!" 路径
```

后续 callee 的错误串实证：`DISP_HAL_Init failed!`、`DISP_DA_Init failed!`、
`DISP_INTF Not inited.`、`FUNC(%s) Error! Invalid input parameters!.`。
→ **[观察]** 这是可定位的显示初始化调用链，不是 `docs/031 §3.2` 那种孤立 rodata。

### 3.2 基址如何变成寄存器访问（`0xc02f02cc`）

```asm
0xc02f02e0  bl  0xc000e130
0xc02f02e4  ldr r4, [0xc02f0570]   ; = 0xc084c870  (全局显示结构体)
0xc02f02e8  mov r6, r0             ; r0 = 传入的物理基址
0xc02f0308  add r6, r6, 0x5000000  ; 物理 → 虚拟映射偏移
0xc02f030c  str r6, [r4, 0x258]    ; 存进全局结构体 +0x258
0xc02f0328  mov r2, 0x10000
0xc02f032c  ldr r0, [..]           ; "VDP_RegBackBuff"
0xc02f0334  bl  0xc030c458         ; 分配寄存器备份缓冲
```

→ **[推断]** 驱动把 ioremap 后的 VO 寄存器虚拟地址缓存在 `0xc084c870+0x258`，
后续读写经该结构体指针 + 偏移完成，因此基址常量在代码里只出现 1–2 次、
**不直接邻接 MMIO `str`**。这与 `docs/031 §5.1` 在 hiboot 里「找不到基址字面量」并不矛盾：
内核与 bootloader 用的是不同访问模型。

### 3.3 一个必须排除的假阳性（REA 方法论应用）

在 `0xc02f0000–0xc0320000`（DISP 代码区）统计到 **5183 条** `str rX,[rY,#imm]`。
抽样全部是 `str r1,[fp,#-0x40]` / `str r3,[fp,#-0x58]` 之类的**栈帧局部变量存取**，
不是 MMIO 写入。
→ **[观察/排除]** 不能把「大量 str 指令」当作「寄存器初始化序列」。
`docs/033 §2` 第 3 条「不靠指令外观推断行为」在此生效；若把它写成序列即是编造。

---

## 4. 与既有文档的关系

| 文档 | 关系 |
|---|---|
| `docs/031` hiboot 负结果 | 本文**补上它做不到的内核侧**：`docs/031 §7.1` 建议「反汇编 p11 vmlinux」，本文用更直接可得的 recovery vmlinux 先走到了「代码可达 + 调用链」，但**同样尚未取得寄存器写入表**。两份文档的诚实边界一致。 |
| `docs/032 §7` 七条待验证清单 | 第 1（HDMI 初始化调用链）、第 2（VO 图层配置）、第 4（时钟/复位）：本文给出第 1 条的**入口坐标**（`0xc03180c0`），第 2/4 条仍 `unresolved`。 |
| `docs/023 §4.2 / §4.3` SDK 推测 | `0xf8cc0000` 作为 VO 基址被**固件代码实证**使用（§2.3 / §3.1）；但 G0 偏移 `+0x494/+0x49c/+0x4a0` 仍只有 SDK 推导，本文未验证。 |
| `docs/029` 发送器形态 | `0xf8ce0000` 在这份内核里被 help 函数引用、`0x08ce0000` 0 命中（§0 存疑）。**不推翻 `docs/029`**，需另行厘清映射/多 chip 条件编译。 |
| `patches/kernel/hi3798mv100-hdmi-console.c` | `VO_REG_BASE=0xf8cc0000` 获得固件实证；`HDMI_TX_BASE=0xf8ce0000` 是否应改 `0x8ce0000` 仍按 `docs/029` / `docs/031 §5.2` 结论处理，本文不新增断言。 |

---

## 5. 仍未知 / 下一步（交给专职成员继续）

1. **追 `0xc084c870+0x258` 字段的读取点**：谁 `ldr` 该字段、再以什么偏移 `str` 写入
   → 才能得到真正的 MMIO 寄存器写入序列。这是当前最高价值的一步。
2. **定位 HDMI 初始化函数体**：`0xc02e21a0` 所在 `/proc/msp/hdmi0` 帮助函数的邻居，
   以及 `HI_DRV_HDMI_Init/Open` 的真实入口（注意 `docs/033 §4`：kallsyms 压缩，
   不能靠字符串地址定位）。
3. **EDID / 时钟 / 复位**：`SI_ReadEDID` 的 2 个指针引用指向什么；`clk_set_rate` 调用点；
   CRG 寄存器——对应 `docs/032 §7` 第 3/4/5 条。
4. **与 SDK 逐字节核对**：把取得的序列与 `hdmi_1_4/hdmi.c` 的 `HDMI_Display()`、
   `hi_reg_vdp.h` 的 G0 偏移对照（pmOS / odin 经验，`docs/025 §2.2`）。
5. 全程遵守 `docs/033` 规范：三分法、独立 oracle、不靠 strings / 指令外观推断、
   空结果只写「范围内未检索到」、结论带对象 SHA-256 与工具版本。

---

## 6. 复现与合规

- 扫描脚本与日志：`TMP/recovery-deep/`（gitignored，不入库）。
- 工具：radare2 6.2.4（`r2 -a arm -b 32 -m 0xC0008000 -q -c 'pd N @ ADDR'`）、
  capstone 5.0.7（`Cs(CS_ARCH_ARM, CS_MODE_ARM|CS_MODE_LITTLE_ENDIAN)`，`skipdata=True`）、
  Python 3.14.6、Node v26.12.1。
- 对象 SHA-256 见文首；本地资源一律用仓库内相对路径，**不含本机绝对路径 / 用户名 / 卷名**；
  厂商构建机标识省略。
- 只读静态分析；未刷机、未改真机、未构建镜像、未删文件、未访问项目外目录、未动 git 索引外的文件。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
