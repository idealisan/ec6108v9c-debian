# 033 — 引入 REA 逆向方法论并落地到本项目固件分析

> 2026-11-08。用户提供 `morluto/rea`（Reverse Engineer Anything）仓库，要求「学习技能、应用到项目中」。
> 本文记录：学到了什么、本机哪些能力真的可用、以及**如何把方法论施加到正在进行的
> 原厂 Recovery / hiboot 显示初始化逆向**（`docs/031` hiboot 四问、`docs/035` recovery 链路、`docs/032`）上。
>
> 相关文档：`docs/032`（recovery 第一突破口研究计划）、`docs/035`（recovery 初始化链路实证）、`docs/031`（hiboot 四问）、
> `docs/023`（recovery 显示逆向）、`docs/027`（整机备份静态分析）、
> `docs/029`（发送器形态厘清）、`AGENTS.md`

---

## 0. 结论先行

1. REA 的价值对我们**主要是方法论，不是工具链**：它的 MCP 原生反汇编需要
   Ghidra / IDA / Hopper / Kuna，本机一个都没有；固件提取需要 Binwalk / Unblob，也没有；
   Node 是 `22.23.1`，低于 REA 最低要求 `22.23.4`。且 `npx rea-agents setup` 会修改
   项目外的 agent 配置（需用户授权），**本次不安装、不注册 MCP、不装 Ghidra/Java**。
2. 但 REA 的证据链规范**正好命中本项目此前几次翻车的原因**，应作为
   `docs/031`/`docs/035` 及后续所有逆向文档的强制写作规范（§2）。
3. REA 的 `raw-binary` 思路（显式给 `architecture` + `entry_point`，不从后缀猜 CPU）
   可以用本机已有的 **capstone 5.0.7** 落地。已实测：recovery vmlinux 按
   `ARM:LE:32:v7` / 链接地址 `0xC0008000` 反汇编，解出标准 ARM Linux `stext`
   入口且 PC 相对地址自洽（§4）。
4. 按 REA「pin the baseline / target digest」原则，已固定六个待分析二进制的
   SHA-256（§5），后续每份结论都应引用它，避免"哪份镜像"含混。

---

## 1. 仓库与技能清单（来源）

- 上游：`morluto/rea`，版本 `rea-agents 6.8.0`，浅克隆于项目内 `TMP/rea/`
  （`TMP/` 已 gitignored，**不入库**；本文不记录任何本机绝对路径）。
- 定位：「One MCP for reverse engineering」，把 agent 接到原生二进制 / JS/Electron /
  .NET / 固件 / 网页的分析工具上，结果**附带证据与限制**；也可纯 CLI 使用。
- 5 个技能（`.agents/skills/*/SKILL.md`）：
  `reverse-engineer-anything`（主技能：目标路由 + 调查工作流）、
  `rea-analysis-optimization`（性能与正确性 oracle）、
  `rea-tool-design`、`rea-ci-tests-audit`、`rea-changelog-update`（后三个是 REA 自身工程用，与本课题无关）。
- 主技能的 7 份参考：`native-and-artifacts.md`、`evidence-workflows.md`、
  `javascript-applications.md`、`android-applications.md`、`runtime-observation.md`、
  `environments.md`、`connection-and-recovery.md`。
- 与本课题直接相关的指南：`docs/providers/raw-binary.md`、
  `docs/guides/native/native-investigation.md`、`docs/guides/native/binary-diagnostics.md`、
  `docs/guides/firmware/firmware-analysis.md`。

REA 主技能自己也划了边界：**「对完整源码仓库的普通分析用常规工具，不要跑 REA」**；
REA 只用于「结论依赖已发布二进制 / 包 / 反编译 / 版本比较」的场景。本项目分析的是
原厂固件二进制（无源码），正是它的适用范围。

---

## 2. 学到的原则，逐条映射到本项目

| # | REA 原则（出处） | 本项目此前的问题 | 今后强制要求 |
|---|---|---|---|
| 1 | **三分法**：每个结论区分 `observation` / `inference` / `unknown`；保留 limitations 与 coverage；「never imply that static analysis observed execution」（主技能 §Work summary-first / §Finish） | 把「看到 Debian Linux logo」当成「刷机成功」；把「`0xf8ce0000` 常量出现」当成「mv100 片内 HDMI TX 输出」 | 每条结论标注 `[观察]` / `[推断]` / `[未知]`；静态分析不得写成「运行时执行了…」 |
| 2 | **空结果只证明检查范围内不存在**：「An empty result proves absence only within the actually examined scope」；「A missing record is an unknown, not proof of absence」（`rea-analysis-optimization`、各 target 指南反复出现） | `docs/027 §6` 用「全库 `sii9134` 字面量 0 命中」推翻 `docs/025 §8`，后被 `docs/029` 撤销 | 「0 命中」只能写「在 X 范围内未检索到」，不得推出「不存在」；SDK 可能用 `SI_` / `SiI_` 前缀封装 IP |
| 3 | **不靠文件名 / 字符串 / 布局推断行为**：「do not infer behavior from filenames, strings, or layout alone」（主技能 §Plan broader investigations 第 4 步）；「Format matches are inferences, not handler identity or schemas」 | `docs/027` 只做 strings / 4 字节常量扫描就下硬件形态结论 | strings 只能列「证据清单」；硬件行为必须有反汇编 / 交叉引用 / SDK 源码三方之一佐证 |
| 4 | **用所需证据类型佐证**：「Corroborate a conclusion with the evidence type it requires. Static differences remain candidates, not causal proof」（主技能 §Plan 第 5 步、`native-and-artifacts.md`） | `docs/023 §4` 因解不出 vmlinux，内核侧只能靠 SDK 源码推测 | 结论优先「实际刷入的固件二进制实证」；SDK 推测只作交叉验证，冲突时以固件为准（`docs/032 §3` 已定） |
| 5 | **Summary-first、不重复**：先最小总览 → 用 `parent_evidence_id` 分页；「Do not repeat an identical analysis or rejected call without a changed input or resolved blocker」（主技能 §Work summary-first） | 多次重复解包 / 重复扫同一批字符串 | 先做区域 / 符号 / 字符串总览，再按具体假设聚焦；记录已做过什么，避免重复 |
| 6 | **Checklist + finding ledger**：把请求拆成问题清单 → 每条结论链接证据 ID、置信 / 证据类型、搜索边界、剩余未知 → 完成前回查清单，标 `answered` / `partially` / `unresolved`（主技能 §Plan broader investigations） | 之前结论散落在对话与 `TMP/` 笔记里，`docs/027 §7.1 C` 的待办没有逐条销账 | `docs/032 §7` 七条待验证清单即本项目 checklist；`docs/035` 须逐条给结论或标存疑 |
| 7 | **Pin the baseline / correctness oracle**：记录 baseline revision、target digest、engine identity、options、host、entrypoint；oracle 独立于被验证的实现（如「独立映射的文件字节」） | 多份 recovery / fastboot 镜像混用，数值互引（见 `docs/027 §3.3`） | 每个结论注明对象 SHA-256（§5）、工具版本、架构 / 链接地址；跨镜像数值不得互引 |
| 8 | **配置与资源一起看**：「Inspect relevant packaged resources and configuration alongside code」（主技能 §Plan 第 4 步） | 分析 vmlinux 时容易忽略 baseparam / bootargs / ramdisk init.rc | recovery 显示链路必须同时看：`bootargs`（`mmz=`、`console=`）、`p05_baseparam`（DISP 参数 / 空 EDID 缓存）、ramdisk `init*.rc` / `ueventd*.rc`、`/sbin/recovery` 的 fb0 用法 |
| 9 | **目标路由、不猜**：`raw-binary` 必须显式给 `architecture` + `entry_point`；「REA does not infer the CPU from the file suffix, guess the reset vector, or emulate the target」（`docs/providers/raw-binary.md`） | 旧脚本把 zImage 当 vmlinux、按 gzip 魔数找 xz 内核、见到第一个魔数就认定 | 格式与加载地址一律显式声明并验证（见 §4），不从后缀 / 首字节猜 |
| 10 | **分解独立问题**（主技能 §Plan 第 6 步） | — | 本课题按用户偏好只保留一名专职研究员做提前研究，不铺开团队并行；但 `docs/035` 内部按 7 个独立分节，等价于问题分解 |

---

## 3. 本机工具链评估（诚实清单）

| 能力 | 状态 | 说明 |
|---|---|---|
| REA MCP / CLI 原生反汇编 | **不可用** | 需要 Hopper / Ghidra / IDA / Kuna，本机均无；`analyzeHeadless`、`ghidra`、`ida64`、`hopper` 均不在 PATH，`GHIDRA_INSTALL_DIR` 未设 |
| REA 固件提取 `inspect_firmware_regions` / `extract_firmware` | **不可用** | 需要 caller-supplied Binwalk / Unblob（Linux），本机均无 |
| REA 内置 target-free 静态检查（ELF notes / kernel module / hardening / Go / Rust …） | **不适用** | 这些要求 ELF/PE/Mach-O 容器；我们的 vmlinux、fastboot.bin 是**无 ELF 头的 raw ARM 镜像** |
| Node.js | 版本不足 | `v22.23.1`，REA 最低 `22.23.4`（或 24.x ≥24.22.1 / 26.12.1+） |
| `/usr/bin/objdump` | 不支持 ARM | `objdump --info` 无 arm 条目 |
| **Python capstone 5.0.7** | **可用** | 本机唯一可用的 ARM 反汇编器，能落地 `ARM:LE:32:v7`（§4） |
| `pyelftools` | 未安装 | 需要时自写轻量解析即可，不引入依赖 |
| `nm` / `strings` | 可用 | 但 raw 镜像无 ELF 符号表，`nm` 帮不上 |

**据此决定**：不安装 REA 运行时、不注册 MCP、不改项目外配置、不装 Ghidra/Java；
只把 §2 的方法论作为规范，把 §4 的 raw-binary + capstone 作为落地手段。
这与 `AGENTS.md`「CI 只做重构建、本地只做轻量校验」「临时产物放项目内 `TMP/`」一致。

---

## 4. 落地验证：`raw-binary` 思路用 capstone 实现

REA `docs/providers/raw-binary.md` 的约束照搬：

```
open_binary(path, format="raw-binary", architecture="arm", entry_point="0xC0008000")
→ Ghidra 用 ARM:LE:32:v7、小端、A32 起始；不支持 Thumb-only / 大端 ARM；
  文件 offset 0 映射到 entry_point；不猜 CPU、不猜 reset vector、不模拟执行。
```

本机用 capstone 等价实现（最小可复现片段）：

```python
from capstone import *
md = Cs(CS_ARCH_ARM, CS_MODE_ARM | CS_MODE_LITTLE_ENDIAN)
for i in md.disasm(vmlinux[:80], 0xC0008000):
    print(hex(i.address), i.mnemonic, i.op_str)
```

**实测结果（观察）**：解出标准 ARM Linux `stext` 入口——
`bl #0xc0013460` → `mrs sb, apsr` / `eor` / `tst` / `bic` / `orr` →
`bne` → `orr sb,sb,#0x100` → `add lr,pc,#0xc` → `msr spsr_fsxc` / `msr elr_hyp` /
`eret` → `msr cpsr_c,sb` → `mrc p15,#0,sb,c0,c0,#0` → `bl #0xc0560e98` …
PC 相对目标全部落在同一 8 MiB 映像内且指令语义连贯，
**故 `0xC0008000` 链接地址成立**（`PAGE_OFFSET=0xC0000000` + `TEXT_OFFSET=0x8000`，
符合 3.10 ARM 内核惯例）。这是后续所有反汇编 / 交叉引用的地址基准。

**kallsyms 约束（观察）**：vmlinux 里
`kallsyms_addresses` / `kallsyms_offsets` / `kallsyms_names` / `kallsyms_num_syms` /
`kallsyms_token_table` / `kallsyms_token_index` / `kallsyms_markers` / `/proc/kallsyms`
**全部 0 命中**；只有 `kallsyms` 3 次、`__ksymtab_` 3 次、`__kcrctab_` 2 次。
而 `docs/032 §6.3` 扫到的 `HI_DRV_HDMI_Init` 等完整函数名字符串，
应来自 `__func__` / `EXPORT_SYMBOL` / proc 接口名，**不是符号表条目**。
→ **不能靠「字符串地址」直接定位函数地址**（这正是 §2 第 3 条要防的推断）。
要拿函数地址，须解析压缩 kallsyms（token 表 + 地址数组）或 `__ksymtab_` 导出符号表，
或由已知入口沿 `bl` 调用图推。此项列入 `docs/035` 的实证任务（已由压缩 kallsyms 重建完成）。

---

## 5. 分析基线台账（target digest）

以下为本次及后续分析对象的 SHA-256；任何结论引用对象时须带其中之一。

| 对象（仓库内相对路径） | 大小 | SHA-256 | 角色 |
|---|---|---|---|
| `TMP/recovery-deep/recovery-vmlinux.bin` | 8,227,512 B | `d91d91049db9893c5a5811826b73a79e58f82330a669729bee58713706ac6e7d` | recovery vmlinux，xz 解出，反汇编主对象 |
| `TMP/rec-zImage` | 2,822,584 B | `a61d35da572a12a6d66863b5b772c4b6b0b9db021f3b0d44fa32e6c777bf5896` | xz piggy 容器（真 piggy @ `0x391f`） |
| `TMP/p3_recovery.img` | 16,777,216 B | `a1609a50736821252135faab8b029faec340d24d140bd5fe84a7b63010c0e845` | 原厂 recovery 分区，含两个 boot.img 槽 |
| `TMP/community-restore/fastboot.bin` | 539,264 B | `fd5b4ac6ce4d50e8a127957dc86a2d2fa503d150db2abca014033ad4e7de7f0b` | 社区 U 盘刷机执行者 hiboot 本体 |
| `backup_stock/fastboot.img` | 1,048,576 B | `bac0be9ff5926de1c813668216977c85e1903ceb3e69b83e5a7ffb2156b0c073` | 原厂 p1 fastboot/hiboot |
| `backup_stock/p01_fastboot_adb.img` | 1,048,576 B | `bac0be9ff5926de1c813668216977c85e1903ceb3e69b83e5a7ffb2156b0c073` | 与上者 **字节完全相同**，是同一文件的另一份拷贝，**不是另一构建** |

> 最后一行纠正了此前「`p01_fastboot_adb.img` 是另一构建」的口误：
> 两者 SHA-256 一致，按 §2 第 7 条，不得把它们当两个独立样本互引数值。

工具 / 环境基线：`Python 3.14.6`、`capstone 5.0.7`、`Node v22.23.1`、
架构 `ARM:LE:32:v7`、链接地址 `0xC0008000`（已由 §4 验证）。

---

## 6. 施加到当前工作的具体动作

1. **`docs/035`（recovery HDMI 初始化链路逆向）**：写作规范升级为 §2 的十条；
   6 个分节各自保留「观察 / 推断 / 未知」标注与 finding ledger；
   对 `docs/032 §7` 七条待验证清单逐条 `answered` / `partially` / `unresolved`；
   寄存器序列必须标明来自哪份 SHA-256 对象、哪个地址、用什么工具解出。
2. **`docs/032` 已定**：「固件实证优先于 SDK 推测」（§3）与 §2 第 4 条一致，保持不变。
3. **`docs/027 §6` 的旧误判**：继续以 `docs/029` 的撤销为准；§2 第 2 条解释了它
   为什么会翻车（把「0 命中」当成「不存在」），不再重复该推理模式。
4. **地址基准**：`0xC0008000` 与 capstone 片段写进 `docs/035`，作为所有
   `bl` 目标 / 常量交叉引用的统一基准（§4）。
5. **配置一起看**：分析 HDMI 链路时同时引用 `bootargs`（`mmz=`、`console=`）、
   `p05_baseparam`（DISP 参数 / 空 EDID 缓存）、ramdisk 的 fb0 用法（§2 第 8 条）。

---

## 7. 明确不做的事

- 不运行 `npx rea-agents setup` / `rea setup` / `rea doctor`：会改项目外的
  agent 配置并需要用户授权，且本机缺引擎，注册了也做不了原生反汇编。
- 不在本机安装 Ghidra / Java / IDA / Hopper / radare2 / Binwalk / Unblob
  （重装、耗时、且用户已明确本地不做重活）。
- 不把 `TMP/rea/`（7621 个文件）或任何外部仓库内容提交进本仓库；本文只记录
  方法论与结论，不复制 REA 源码。
- 不因为装了方法论就宣称「用了 REA 工具」——本机只用了它的**规范**与
  **raw-binary 思路**，实际反汇编器是 capstone，须如实标注。
- 不做本地镜像构建 / rootfs 打包（一律 CI）。

---

## 8. 合规

- 只读静态分析；不刷机、不改真机、不联网（浅克隆只读一次上游仓库）、不构建镜像。
- 临时产物统一在项目内 `TMP/`；不删除文件、不 `git clean`、不访问项目目录之外的目录。
- 文档不含本机绝对路径 / 用户名 / 卷名；上游仓库以仓库名 + 版本标识，不写入库。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；
  纯 `docs/` 改动不触发任何 build workflow。
