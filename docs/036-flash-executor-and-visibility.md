# 036 — 刷机执行者的确定，与「让刷机过程可见」的改造前置分析

> 2026-11-08。用户指令：**分析清楚显示的激活和使用流程之后，先确定刷机动作由哪一个程序执行，
> 再把该执行者改造成能显示画面**，否则刷机流程走到哪一步无从得知。
>
> 本文完成前两步（确定执行者 + 把「为什么它不显示」用证据钉死），并列出第三步的
> 候选改造路径与各自依赖/风险。**实际改造待 `docs/035`（显示激活/使用流程逆向）结论回来后动手**，
> 因为方案选择依赖「开机显示路径由谁触发、VO 显存地址从哪来」这两个尚未确定的事实。
>
> 相关：`docs/031`（hiboot 四问实证）、`docs/032`（recovery 计划）、`docs/033`（REA 方法论）、
> `docs/034`（recovery vmlinux 显示代码实证）、`docs/024`（回归/诊断审计）、`docs/029`（发送器形态）

---

## 0. 结论先行

| # | 问题 | 结论 | 置信 |
|---|---|---|---|
| 1 | **刷机动作由哪一个程序执行？** | **eMMC p1 上的 hiboot（Fastboot/U-Boot 派生）**。触点短接上电 → BootROM 加载 p1 → 它读 U 盘**顶层** `bootargs.bin`（CRC32 env）→ 执行 `bootcmd`。**U 盘里的 `fastboot.bin` 不是执行者，只是被 `mmc write` 当作数据写进 p1 的载荷。** | 实证（确定） |
| 2 | 它为什么现在不显示任何画面？ | 三条同时成立：① 命令表无显示命令（`docs/031 §2`）；② console 设备表只有 `serial`（`docs/031 §4`）；③ **U 盘刷机分支不做显示初始化**（`docs/031 §3`）。刷机时「背光都不亮」正对应这条路径。 | 实证（确定） |
| 3 | 社区包为什么「看起来能显示」？ | 社区包 `bootcmd` **第一步 `run flashfastboot` 会把自己的 `mv100/fastboot.bin` 刷进 p1**，`reset` 后由这份新 hiboot 走**正常开机路径**画 p5 logo。**我们的包不刷 p1**，所以执行者一直是盒子上原有的 hiboot。两者差别在 p1 是否被替换，不在刷机过程本身会显示。 | 实证（确定） |
| 4 | 「Debian Linux」画面是什么？ | p5/p7 logo 分区内容在**另一次正常开机**被画出，不是刷机进度，也不证明刷机成功（`docs/031 §2.3`、`docs/024 §6.1`）。 | 实证（确定） |
| 5 | 153551Z 全黑回归的根因？ | **修正一个旧推断**：4 张 stage logo 的 `LOGO_TABLE` 容器与能显示的 Debian logo 结构完全一致（`###\0` / key_flag=4 / JPEG @`0x2000` / 合理 key_len），素材格式合法 → 全黑更可能来自 `&&` 串行链本身（vendor hush 不解析），而非 logo 文件损坏。`docs/024 §6.2` 的结论成立。 | 观察 + 修正 |

---

## 1. 执行者是谁（证据链）

### 1.1 启动链

```
触点短接上电
  → BootROM（芯片固化，从 eMMC boot 区 / p1 取码）
  → p1 hiboot / fastboot（Fastboot 3.3.0，U-Boot 派生，带 hush）
      读 U 盘 FAT32 顶层 bootargs.bin  → CRC32 校验 → 载入 env
      执行 bootcmd（一串 run/fatload/mmc write/reset）
  → reset → 重新走开机路径（显示 p5 logo 或 bootm kernel）
```

`bootargs.bin` 结构：4 字节 CRC32 + NUL 分隔 `key=value`，64 KiB。三份实测 CRC 全 OK。

### 1.2 决定性差异：社区包刷 p1，我们的包不刷

| | 社区包 | 我们官方包 |
|---|---|---|
| U 盘顶层 `fastboot.bin` | **有**（539,264 B） | **无** |
| U 盘内层 `mv100/fastboot.bin` | 有（539,272 B，与顶层 126,498 字节不同，属不同构建） | 无 |
| `flashfastboot` | `loadfilef=fatload usb 0 0x1000000 mv100/fastboot.bin`<br>`flashpartitionf=mmc write 0x0 0x1000000 0x0 0x0440` | 不存在 |
| `bootcmd` | `run flashfastboot; run flashbootargs; run flashbase; run flashpq; run flashlogo; run flashkernel; run flashrootfs; run flashbackup; reset` | `run flashkernel; run flashrootfs; run flashbootargs; run flashlogo; reset` |
| 是否替换 p1 | **是（第一步）** | **否** |

实测补充：
- 我们官方 release zip 共 9 个条目，`fastboot` **0 命中**（`mv100/debian-root.ext4`、`hi_kernel.bin`、`logo.img`、`bootargs.bin` 等），确认「不刷 p1」是包结构层面的事实，不是漏看。
- 社区 `flashpartitionl=mmc write ... 0x5000 0x120`（写 logo 分区 144 KiB），我们 `0x5000 0x80`（64 KiB）——只是写入长度不同，都**不触发显示**。
- 社区内层 `mv100/bootargs.bin` 的 `bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0` 是**正常开机**（拔 U 盘后）用的；顶层 `bootargs.bin` 是**插 U 盘刷机**用的。两层分工清楚。

### 1.3 由此确定的执行者身份

> **执行者 = 刷机前 p1 里那份 hiboot。**
> 用户此前刷过社区 Ubuntu（该包刷 p1），之后刷我们的包（不刷 p1），
> 因此当前 p1 很可能是社区 `mv100/fastboot.bin` 那份。
> **U 盘顶层 `fastboot.bin` 只是 `flashfastboot` 要写进 p1 的数据**，
> 在「我们的包」里连这个文件都不存在。
>
> 推论（重要）：**同一份 hiboot，正常开机路径会显示、U 盘刷机路径不显示**——
> 差别不在二进制是否具备显示能力，而在**走哪条分支**。
> 这正是「改造执行者」的着力点：不是换一份 hiboot，而是让刷机分支也触发显示初始化。

---

## 2. 为什么执行者现在不显示（三条实证，来自 `docs/031`）

1. **命令表无显示命令**：28 字节 `cmd_tbl_s` 表（原厂约 45 项 / 社区约 54 项）含
   `go` `reset` `bootm` `fatload` `mmc` `mw` `crc32` `setenv` `saveenv` `printenv` `run` 等，
   但**没有 `logo` / `logobak`、没有任何显示/HDMI/图形命令**。`logo` 只是 PDM 参数键名。
   → `bootcmd` 里不存在「插入一条命令重画 logo」的写法。
2. **console 设备表只有 `serial`**：无 `vidconsole` / `vesa` / `cfb_console` / `lcd` / `nulldev`。
   改 `stdout=` 不能把 `fatload`/`mmc write` 日志送到 HDMI；本机又无串口 → 刷机过程完全不可观测。
3. **刷机分支不做显示初始化**：`PRODUCT_DisplayInit` / `Logo_Main` / `HI_GFX_ShowLogo`
   在 4 份 hiboot 的全量交叉引用（7 种方法）**全负**，字符串是孤立 rodata。
   `bootcmd` 展开全是分区搬运 + `reset`，无显示调用。
   → 用户「刷机时背光都不亮」对应这条路径；「Debian Linux 画面」来自另一次正常开机。

> 注意 `docs/031 §3.4` 的**存疑边界**：显示字符串调用点定位不到，不能据此断言
> 「硬件上不存在显示初始化」，只能说「这批镜像里没有可定位的显示入口」。

---

## 3. 一个需要修正的旧推断（stage logo 素材合法）

对 5 张静态 logo 资产做 `LOGO_TABLE` 头解析：

| 文件 | 大小 | magic | key_flag | key_len | JPEG @`0x2000` |
|---|---|---|---|---|---|
| `boot-logo-debian.img`（能显示） | 65,536 | `###\0` | 4 | 29,497 | `ffd8ffe0 ... JFIF` |
| `boot-logo-stage0.img` | 65,536 | `###\0` | 4 | 25,054 | 同上 |
| `boot-logo-stage1.img` | 65,536 | `###\0` | 4 | 29,369 | 同上 |
| `boot-logo-stage2.img` | 65,536 | `###\0` | 4 | 29,459 | 同上 |
| `boot-logo-stage3.img` | 65,536 | `###\0` | 4 | 25,981 | 同上 |

→ **全部容器结构合法、与能显示的 Debian logo 同构**。
`docs/024 §6.5` 记录的 153551Z 全黑回归，因此**不是「stage 图片写坏 p5 容器」**；
`docs/024 §6.2`「vendor hiboot 有 `HUSH_VERSION` 但无 `&&` 解析证据、串行链导致异常」
是更可信的解释。**分级 stage logo 这条素材路线本身仍然可用**，只是不能用 `&&` 串联。

---

## 4. 第三步：让刷机执行者显示画面 —— 候选路径与依赖

### 路径 A：改 p1 hiboot（最根本，但最重）

在 U 盘刷机分支进入 `bootcmd` **之前**触发一次显示初始化（`PRODUCT_DisplayInit` / `Logo_Main`
一类入口），使 HDMI 在刷机期间保持点亮，之后每步可刷新 p5 或直接改显存。

- 前置依赖：必须定位到该入口的**运行时地址**（`docs/031` 全量交叉引用为负，标存疑）。
  命令表里有 `go`（跳任意地址执行），理论上可用 `go <addr>` 调用，但地址未知。
- 手段：二进制 patch 现有 hiboot，或用 HiSTB SDK 重新编译一份带显示命令的 hiboot 并刷 p1。
- 风险：**刷 p1 是高风险真机动作**（刷错需触点 + U 盘兜底）；与既有「不动 p1」约束冲突，
  需用户明确授权。本地不编译（交 CI / 用户既有 SDK）。

### 路径 B：分阶段 `reset` + 阶段 logo（不改 p1，利用已验证的开机显示路径）

把长链拆成 N 个阶段：每阶段完成 → 写一张「阶段 N 完成」的 stage logo 到 p5 → `reset`。
`reset` 后 hiboot 走**正常开机路径**，必然画出 p5 的 logo → 用户看到进度。
用 `;`（已知可跑完，**不用 `&&`**）+ env 状态变量递进到下一阶段。

- 已具备：4 张 stage logo 容器合法（§3）、`flashlogo` 写 p5 的命令现成、`;` 链已知可跑完。
- **未确定的关键未知**：`reset` 后 hiboot 从**哪里**重载 env（U 盘顶层 `bootargs.bin` 会覆盖 RAM env，
  `saveenv` 写回的是 eMMC p2）。若每轮都从 U 盘读同一份 env，状态无法递进 → 会反复刷第一阶段。
  这决定状态机能否成立，**必须在改造前查清**（`docs/035` / hiboot 反汇编）。
- 风险：中等。之前 `&&` + stage logo 全黑翻过车，本路径刻意避开 `&&`，但 `reset` 次数增多、
  每轮重新 fatload，耗时与写 p5 次数都上升；需保证**任何时刻 p5 都持有一张合法 logo**（§3 已确认素材合法）。

### 路径 C：只改 `stdout` 到视频（已排除）

`docs/031 §4` 实证 console 设备表只有 `serial`，指定未注册设备名只会报错/回退。
**不可行**，不再考虑。

### 路径取舍建议

| | 是否改 p1 | 是否依赖显示激活流程 | 主要未知 |
|---|---|---|---|
| A | **是（高风险）** | 强依赖（要入口地址） | 入口地址定位不到 |
| B | 否 | 中等依赖（env 重载语义） | `reset` 后 env 来源 |
| C | 否 | 无 | 已排除 |

→ **优先把 B 的未知查清**：它不改 p1、素材已就绪、`;` 链已验证，是最低风险且可逆的一条。
但 B 成立与否取决于 `reset` 后的 env 重载语义，而这属于「显示/启动激活流程」，
正是 `docs/035` 在做的范围。**因此第三步等 `docs/035` 回来再动手**，避免在未知上叠改造
（这正是 153551Z 翻车的原因：在 `&&` 语义未验证时改了链）。

---

## 5. 与用户给定顺序的对应

1. **「分析清楚显示的激活和使用流程」** → `docs/034` 已给出 `DISP_Init` 入口与调用链实证，
   `docs/035`（专职成员进行中）负责追到真实寄存器写入序列、EDID/时钟/复位。
2. **「先确定下来刷机的动作是由哪一个程序执行的」** → 本文 §1 **已完成并交付**（p1 hiboot）。
3. **「把执行者改造成能显示画面」** → 本文 §4 列出路径与依赖；**待 `docs/035` 结论后执行**，
   优先验证路径 B 的 env 重载语义，必要时再评估路径 A 及是否授权刷 p1。

---

## 6. 合规

- 全程只读静态分析与文件清单核对；未刷机、未改真机、未构建镜像、未删文件、
  未访问项目目录之外的目录、未动 git 索引外的文件。
- 临时产物与素材均在项目内 `TMP/` / `patches/kernel/`；描述本地资源只用仓库内相对路径，
  **不含本机绝对路径 / 用户名 / 卷名**；厂商构建机标识省略。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
- 结论按 `docs/033` 规范区分观察 / 推断 / 存疑；「0 命中」只写「范围内未检索到」，不推出「不存在」。
