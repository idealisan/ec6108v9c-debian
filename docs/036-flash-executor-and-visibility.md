# 036 — 刷机执行者的确定，与「让刷机过程可见」的改造前置分析

> 2026-11-08。用户指令：**分析清楚显示的激活和使用流程之后，先确定刷机动作由哪一个程序执行，
> 再把该执行者改造成能显示画面**，否则刷机流程走到哪一步无从得知。
>
> 本文完成前两步（确定执行者 + 把「为什么它不显示」用证据钉死），并列出第三步的
> 候选改造路径与各自依赖/风险。改造的**硬约束已查清**：不改 p1 就做不到「过程中实时显示」，
> 但有一条零风险的最小改造（每步写 stage logo 到 p5）可立即提供进度判读。
> 是否改 p1 属高风险动作，需用户明确授权。
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

### 3.1 hush 关键字表实证（补强 `docs/024 §6.2`）

对社区 `fastboot.bin` 做「独立 NUL 结尾 token + 指针引用」扫描（`BASE=0x00C00000`）：

| token | 独立字符串数 | 指针引用数 | 判定 |
|---|---|---|---|
| `if` `then` `else` `elif` `fi` `for` `while` `until` | 各 1 | 各 1 | 构成一个**连续 8 项指针表**（`@0x7e67c`）→ hush 解析器关键字表 |
| `case` `esac` | 0 | — | 无 |
| `&&` `||` | **0** | — | **不作为独立 token 存在**；`strings` 里看到的 `&&` 只是 help 文本字符 |

→ **[观察]** `if/then/elif/else/fi/for/while/until` 条件与循环语法**确实被 hush 解析**（有关键字表）；
`&&`/`||` **不被解析**。这既解释了 153551Z 串行链失败，
也说明分阶段状态机应写成 `if ... then ... fi` + env 变量，**不需要 `&&`**。

> 注意方法论边界（`docs/033 §2` 第 3 条）：上述结论来自「指针表」这一结构化证据，
> 不是「strings 里有 if 就说支持」。
> 更正一处本轮自查：初版扫描把 `bootargs.bin` 的 `@0x00c0c338` 命中当成「NAND/ECC 代码里的
> 数值巧合误报」，实为**口径错误**——`0x00c0c338` 是 `ldr` 的**字面量池条目**（`pxw` 确认其值
> `0x00c77e8c` = 字符串 VA），不是指令。修正后的实证见 §4.1。此处保留更正记录，
> 以体现「结论随证据修正」而非悄悄改口。

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

- 已具备：4 张 stage logo 容器合法（§3）、`flashlogo` 写 p5 的命令现成、`;` 链已知可跑完、
  hush 关键字表证实 `if/then/else/fi` 可用（§3.1）→ 状态机语法无障碍。
- **env 重载语义已查清（§4.1 反汇编实证）**：U 盘顶层 `bootargs.bin` 是**每次上电都重新探测、重新导入**
  的固定文件，`reset` 后状态变量会被原样覆盖 → **`setenv`+`saveenv` 的 env 状态机不成立**。
  必须改用「按 eMMC 已写内容判断进度」或其他不依赖易失 env 的方案。
- 风险：中等。之前 `&&` + stage logo 全黑翻过车，本路径刻意避开 `&&`，但 `reset` 次数增多、
  每轮重新 fatload，耗时与写 p5 次数都上升；需保证**任何时刻 p5 都持有一张合法 logo**（§3 已确认素材合法）。

### 4.1 `bootargs.bin` 加载路径反汇编（env 重载语义实证）

社区 `fastboot.bin`（`BASE=0x00C00000`）中，`bootargs.bin` 字符串 VA `0x00c77e8c`
被 `0x00c0c2a4` / `0x00c0c2cc` 两处 `ldr r0,[pc,#imm]` 引用，字面量池 `@0x00c0c330`
的值经 `pxw` 确认正是 `0x00c77e8c`（此前把它当成 `@0xc338` 代码是**口径错误**，非误报：
`0x00c0c338` 是字面量池条目，不是指令）。

`0x00c0c29c` 起的完整流程：

```asm
0x00c0c2a0  bl 0xc19b98                 ; USB 探测 / 初始化
0x00c0c2a4  ldr r0, [..]="bootargs.bin"
0x00c0c2a8  bl 0xc19bd0                 ; FAT 上查找该文件；失败→返回 1
0x00c0c2ac  subs r4, r0, 0
0x00c0c2b0  beq 0xc0c2c0                ; 找到才继续
0x00c0c2c0  mov r3, 0x1000000           ; fatload 目标地址
0x00c0c2cc  ldr r0, [..]="bootargs.bin"
0x00c0c2d0  bl 0xc19cf4                 ; fatload；r0<=0 视为失败
0x00c0c2e0  mov r2, 0x10000             ; env 尺寸 64 KiB
0x00c0c2e4  mov r1, 0x1000000
0x00c0c2ec  bl 0xc5c9ac                 ; 复制到 env 缓冲
0x00c0c2f8  bl 0xc61e80                 ; (env 处理)
0x00c0c2fc  ldr r1,[r5]; movw r2,0xfffc
0x00c0c30c  bl 0xc5be68                 ; CRC32 校验
0x00c0c31c  cmp r0, r3
0x00c0c324  streq r5,[r3,0x14]         ; CRC 通过→置「U 盘 env 有效」标志
0x00c0c32c  ldr r0, [..]=". bootargs crc failed !."  ; 失败分支
```

→ **[观察]** U 盘 `bootargs.bin` 是**条件加载**（探测到文件 + `fatload` 成功 + CRC 通过才导入并置标志），
不是无条件覆盖；导入的是**文件内容本身**。
→ **[推断]** `reset` 后只要 U 盘仍插着，同一份文件会被重新导入，
`setenv`/`saveenv` 写入的进度状态**不会跨 reset 保留**（`saveenv` 目标是 eMMC p2 env 区，
而刷机模式读的是 U 盘文件）。
→ **[结论]** 分阶段方案若要成立，进度不能存在易失 env 里；
应改为「每阶段把一张**该阶段的 stage logo 写入 p5**，再由 `bootcmd` 依据 eMMC 上已写入的
分区内容判断走到哪一步」，或干脆**不分段**，只在链尾用一张「完成」logo + 一次 `reset`
让用户看到最终结果（最小改动、风险最低）。

> 标注：上述「saveenv 写 eMMC p2」为 U-Boot 通用行为的**推断**，本轮未对 `saveenv`
> 的实现做定向反汇编；「U 盘文件每轮重新导入」为反汇编**观察**。两者区分记录。

### 路径 C：只改 `stdout` 到视频（已排除）

`docs/031 §4` 实证 console 设备表只有 `serial`，指定未注册设备名只会报错/回退。
**不可行**，不再考虑。

### 4.2 一个更根本的约束（决定「改造」能做到什么）

`docs/031 §3` 实证：**U 盘刷机分支不做显示初始化、过程中不刷新 HDMI**；
只有「另一次正常开机」才画 p5 logo。因此：

> **在不改 p1 hiboot 的前提下，「刷机过程实时显示」做不到**——
> 无论怎么改 p5 内容，屏幕在刷机执行期间都不会更新，只有 `reset` 后开机才画一次。
> 路径 B 能提供的上限是「每阶段结束 reset 一次 → 正常开机画一张该阶段 logo」，
> 而 §4.1 又证明 `reset` 后 U 盘 env 原样重导入，会从头再跑 `bootcmd` → 除非用
> `if` + `mmc read`/`cmp` 依据 eMMC 已写内容跳过已完成阶段，否则形成循环。

同时要指出**当前包的真正缺口**：`flashlogo` 本来就在链尾、`reset` 之前，
写的是**一张固定的 Debian logo**。用户看到的正是它。因为 `;` 链无论哪步失败都会继续，
最终总会写这张 logo + reset → **成功、失败、卡在某步，用户看到的画面完全一样**。
这才是「刷机流程走到哪都不知道」的直接根因，而不是「没有显示能力」。

### 路径取舍建议（env 重载已查清后更新）

| | 是否改 p1 | 能否「过程中实时显示」 | 主要代价/未知 |
|---|---|---|---|
| A | **是（高风险）** | **能**（刷机分支也初始化 HDMI） | 显示入口地址在 4 份镜像里定位不到（§2）；刷 p1 失败需触点 U 盘兜底 |
| B | 否 | **不能**（仅每阶段 reset 后显示一次） | 需 `if`+`mmc read`/`cmp` 做阶段跳过；`reset` 次数增多 |
| C | 否 | 不能 | console 只有 serial，已排除 |

**最小可落地、零风险的一步（不改 p1、不分段）**：把「链尾一张固定 logo」改成
**每步执行前先把该步的 stage logo 写进 p5**（4 张素材已验证合法，§3）。
刷机中屏幕仍不亮，但一旦中途卡死，用户断电重启后正常开机画出的 p5 logo
就是「卡在第 N 步」的那张 → **首次提供可判读的进度/失败位置**，
且完全避开 `&&`（用 `;` + `if`）、不触碰 p1、不增加 `reset`。

**真正的「过程中实时可见」必须走 A**（改 p1 hiboot），这是需要用户明确授权的高风险动作。

---

## 5. 与用户给定顺序的对应

1. **「分析清楚显示的激活和使用流程」** → `docs/034` 已给出 `DISP_Init` 入口与调用链实证，
   `docs/035`（**已完成**：重建压缩 kallsyms 得 35,937 符号精确地址，实证
   `hdmi_ProcessCmd` → `DRV_HDMI_Init` → `SI_HW_ResetHDMITX` → `SI_TX_PHY_INIT`
   的 7 次 PHY 寄存器写入）负责追到真实寄存器写入序列、EDID/时钟/复位。
2. **「先确定下来刷机的动作是由哪一个程序执行的」** → 本文 §1 **已完成并交付**（p1 hiboot）。
3. **「把执行者改造成能显示画面」** → 本文 §4 已把能做到/做不到的边界查清：
   `reset` 后 env 重载语义（§4.1）、hush `if`/`&&` 能力（§3.1）、stage logo 合法性（§3）
   均已实证，**不再依赖 `docs/035`**。
   立即执行的是 §4.2 的零风险最小改造（每步写 stage logo 到 p5）；
   「过程中实时显示」需走路径 A 改 p1 —— **用户已于 2026-11-08 明确授权（见 §6）**。

---

## 6. 用户授权改 p1：决策记录与安全门槛

### 6.1 授权与既有硬约束的冲突（必须留痕）

用户在「改造刷机执行者」的三个选项中明确选择 **「授权改 p1 hiboot」**（追求刷机当下实时显示）。
但这与项目早先一条**用户亲自下的硬约束**直接冲突：

> `docs/013-no-p1-touch-plan.md` 开头：「**eMMC 的 p1（hiboot）绝对不写 —— 没有串口线，改坏了无法恢复**」；
> 且「任何刷写都必须能在『无串口』的前提下回滚」。
> `docs/018-debian-flash-guide.md §4`：「p1 hiboot 永远不写，所以 U 盘救援通道始终保留，理论上不会因此变砖」。

`docs/006-restore-to-stock.md` 场景 C 进一步证实：p1 损坏 / 串口无输出时，
救砖**只能**靠 USB-TTL 串口 + HiTool（Windows）重写 p1；本机无串口硬件。
而 `docs/013 §1` 明确：**短接 + 读 U 盘 env 的执行者，正是 p1 里的 hiboot 自身** ——
p1 写坏 → 短接进不了升级模式 → 兜底通道同时失效。

→ 本节记录：授权范围限于「改 p1」，但**不解除**上述物理约束；
授权不等于「立即写」，落笔前必须满足 §6.3 的安全门槛。

### 6.2 本机条件核查（决定改造方式）

| 能力 | 状态 | 影响 |
|---|---|---|
| ARM 交叉编译工具链 | `arm-none-eabi-gcc` / `arm-linux-gnueabihf-gcc` / `mkimage` / `quilt` **全无** | **无法重新编译 hiboot** |
| BootROM 私有头 | `docs/004 §4.3 / §6`：「YZC」头格式未完全逆向，方案 C 暂无可行路径 | 无法生成 BootROM 可接受的新 p1 镜像 |
| SDK 源码 | `TMP/sdk-src/` 仅 227 个文件且多为头文件，无 Makefile / 编译脚本 / YZC 打包工具 | 编译路径不成立 |
| 串口 / HiTool | 无 | p1 写坏不可救 |
| radare2 6.2.4 / capstone 5.0.7 | 已装 | 可做只读反汇编与二进制补丁评估 |

→ **唯一可评估的路径是「二进制补丁 / 复用现有 hiboot 代码」，不是重编译。**
另有一条已验证事实降低风险：社区包 `bootcmd` 第一步 `flashfastboot`
把 `mv100/fastboot.bin` 写进 p1，用户用该包成功刷过机器（`docs/016`）——
即「写 p1」这个动作本身是成功过的，风险集中在「写进去的二进制是否正确」。

### 6.3 落笔前的安全门槛（go/no-go）

1. **先定位显示初始化函数体**：`docs/031 §3.2` 的 7 种交叉引用全负并标存疑，
   需换方法（函数序言 / 调用图）确认 4 份 hiboot 里是否存在可定位的显示函数体。
2. **优先评估零补丁路径**：`docs/031 §2.1` 命令表有 `go`（跳任意地址执行）。
   若能用 `go <addr>` 在 `bootcmd` 里触发显示初始化，则**只改 env、不改 p1 二进制**，
   是风险最低的达标方式（`docs/037` 定向调研进行中）。
3. **若必须补丁**：确认 YZC 私有头 / CRC / 签名（`verify=n`）是否需重算、补丁字节数与偏移，
   并给出已知可引导的回滚镜像。
4. **先在 Live-USB 零写入环境验证**（`docs/013 §2` 方案 A），再写真机 p1。
5. 任一条不满足 → **不写 p1**，退回 §4.2 的零风险分级 logo 方案。

### 6.4 当前状态

- 已派专职成员做 `docs/037-hiboot-display-patch-feasibility.md` 定向只读调研
  （显示函数体定位、`go` 命令可用性、最小补丁与回滚镜像、兜底有效性）。
- **至今未向真机写入任何 p1 字节**，也未改动打包脚本的 `bootcmd`。
- 结论回来后按 §6.3 逐条判定 go/no-go，再决定是否产出新的 p1 镜像。

---

## 7. 合规

- 全程只读静态分析与文件清单核对；未刷机、未改真机、未构建镜像、未删文件、
  未访问项目目录之外的目录、未动 git 索引外的文件。
- 临时产物与素材均在项目内 `TMP/` / `patches/kernel/`；描述本地资源只用仓库内相对路径，
  **不含本机绝对路径 / 用户名 / 卷名**；厂商构建机标识省略。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
- 结论按 `docs/033` 规范区分观察 / 推断 / 存疑；「0 命中」只写「范围内未检索到」，不推出「不存在」。
