# 046 — 刷机/引导阶段「进度可见」落地方案（不依赖 pstore、不改 p1 二进制）

> 2026-11-08。分支 `main`。目标（用户会话级）：**在启动/引导/刷机阶段想办法解决显示，能显示进度条或日志**。
> 用户底线：文字日志最好，但「至少用颜色代表阶段、换色即知道进度」也可；**明确否定 pstore**（刷前刷后都要正常系统、太复杂）。
> 本文是**可执行方案**，不是纯分析。承接 `docs/036/038/039/040`、`docs/031/037` 的负结果。
>
> 注：本文编号 046；团队并行产出的「原厂 p1 逆向」文档用 045，两者不冲突（逆向结论回来后回填 §6 的判据）。

---

## 0. 一句话结论

> **零改 p1、零改固件、只改 U 盘 `bootargs.bin` 文本（CRC 由 `scripts/mkbootargs.py` 自动重算）就能做阶段进度显示。**
> 推荐路径：**分阶段独立 U 盘包 + 阶段图写 logo 分区 + reset**，颜色编码作为第一版最小实现。

用户之前的顾虑（刷机全黑、不知是否进入刷机/走到哪步）由「上电后第一张阶段图立刻出现」直接解决：**看到第一张图 = 已进入刷机流程**。

---

## 1. 已坐实的能力与约束（本轮实证）

| 项 | 证据 | 判定 |
|---|---|---|
| **U 盘根 `bootargs.bin` 的执行者** | `docs/036/038`：短接上电 → BootROM 从 U 盘 FAT32 根加载 `fastboot.bin` → 它读 U 盘顶层 `bootargs.bin` → 跑 `bootcmd`。U 盘根 `fastboot.bin`(sha `fd5b4ac6…`, 539264B) **≠** 内层写 p1 那份(`3bded87f…`, 539272B)。 | ✅ 我们可控 U 盘根文件 |
| **`mw` 支持 32-bit 写** | 三份 hiboot 都有 usage `[.b, .w, .l] address value [count]`；我们自己的 `loadfileb` 已在用 `mw.b 0x1000000 0xFF 0x10000` | ✅ `mw.l <addr> <ARGB> <count>` 语法成立 |
| **hush 条件语法** | `if`/`then`/`else`/`fi`/`while`/`for`/`test` 各 1 个独立 token（社区 fastboot.bin @0x7b24f 起）；命令表有 `setenv`/`printenv`/`run`/`reset`/`go`/`mw` | ✅ 但 `itest`/`setexpr` = 0 → **数值状态机能力弱，别做复杂分支** |
| **「通电立即显示」的载体** | 用户亲眼确认 `TMP/stock-all-images/p07_logo/01_1920x1080.jpg`（p7 logo 分区、单张 1920×1080 JPEG @0x2000、`LOGO_KEY_LEN=190496`、与分区字节逐字节一致）就是原厂开机早期画面 | ✅ hiboot 早期读 logo 分区 → 画图 |
| **`flashlogo` 命令已存在** | 我们官方包 `bootcmd` 链里就有 `flashlogo=run loadfilel flashpartitionl`，`flashpartitionl=mmc write 0 0x1000000 0x5000 0x80`（写 p5 logo 分区） | ✅ 写 logo 分区是现成动作 |
| **`go` 命令** | `go - start OS` / `start application at address 'addr'` usage 串在 | ⚠️ |
| **显示函数名是孤立 rodata** | `PRODUCT_DisplayInit`/`HDMI_Display`/`HI_GFX_ShowLogo`/`boot logo show!!!` 在社区 U 盘根 fastboot.bin 与原厂 p1 里**指针引用 = 0**（本轮核对） | ❌ 不能用 `go <函数名>` 直接触发显示；`docs/031/037` 负结果成立 |
| **刷机链执行时不刷新 HDMI** | `docs/031 §3`：命令表无显示命令、console 只有 serial、刷机分支不做显示初始化；用户「刷机时背光不亮」 | ❌ 刷机链**中途**写显存未必上屏 |
| **显示只在「另一次正常开机」路径** | `docs/039`：社区两张图都是 hiboot 开机画 p5 logo；`flashlogo` 只写分区不显示 | ✅ 显示发生在开机路径，不是刷机链中途 |

→ **决定性约束**：刷机链执行期间即使 `mw.l` 写了显存，也不能保证上屏（VO 可能没初始化）。
→ **但**：每次 **`reset` 之后的开机路径**一定会读 logo 分区并画出来（用户确认的原厂行为）。
→ 所以**可靠方案必须把「显示」挂在开机路径上**，而不是刷机链中途。

---

## 2. 推荐方案：分阶段独立 U 盘包（第一版最小实现）

### 2.1 思路

不追求「一次刷机过程里实时刷新」，而是把刷机拆成 **N 个短阶段**，每个阶段：
1. U 盘根放一份**该阶段专属**的 `bootargs.bin`（`bootcmd` 只做这一个阶段 + 写一张**该阶段颜色的 logo 图**到 p5 + `reset`）；
2. `reset` 后 hiboot 走开机路径，**必然画出刚写进去的那张图**；
3. 用户看到颜色/图 = 知道「已进入刷机、且走到第 N 阶段」。

颜色编码（第一版，用纯色 1920×1080 图，最省事）：
| 阶段 | 颜色 | 含义 |
|---|---|---|
| 上电进入刷机 | 红 | 已进入 U 盘刷机流程 |
| 写 kernel 完成 | 橙/黄 | 阶段 1 |
| 写 rootfs 完成 | 绿 | 阶段 2 |
| 写 bootargs / 收尾 | 蓝 | 阶段 3 |
| 全部完成、准备重启 | 白 | 完成 |

### 2.2 为什么这是「肯定可行」的

- 显示的触发点是 **reset 后的开机路径**（用户确认原厂就是这么显示的），不是刷机链中途 → 绕开「刷机时 VO 未初始化」这个未知。
- 只改 U 盘文本文件 + 静态 logo 图，**不改 p1 二进制、不写 eMMC 之外的东西、不需要 pstore、不需要 Linux 内核**。
- `mkbootargs.py` 已验证可生成 CRC 正确的 `bootargs.bin`（`make-community-flash-package.sh:153` 调用它）。
- U 盘根 `fastboot.bin` 由 BootROM 加载（`docs/038`），短接兜底有效，刷坏可用社区包刷回。

### 2.3 代价（如实说）

- 需要**多次短接上电 / 或多次换 U 盘内容**（每阶段一次），比「一条 bootcmd 跑完」慢。
- 第一版用纯色图，信息量低（只能分辨 5 种阶段）；后续可换成带文字的阶段图（复用 `docs/040` 的点阵字体渲染，已真机证可行）。

---

## 3. 更优方案（待两个未知查清后，可做到「一条 bootcmd 跑完 + 实时换色」）

如果团队逆向 `docs/045`（原厂 p1）确认以下两条，**就可以回到「单次刷机、每步之间 `mw.l` 换色」**，无需多次 reset：

1. **刷机分支执行时 VO/HDMI 是否已初始化并持续扫描显存**（用户「背光不亮」是关键反证；若确认刷机模式 PHY 未开，则此路不通）。
2. **显存物理地址是否固定/跨次上电稳定**（p1 有 `HI_DRV_PDM_AllocReserveMem`、`mmz=...` 提示动态分配；若稳定，可实测一个常量填进 `mw.l`）。

若两条都成立，`bootcmd` 模板（**只改文本**）：

```
# 阶段颜色：红=进入刷机 黄=kernel 绿=rootfs 蓝=收尾 白=完成
stage0=mw.l <FB_ADDR> 0xffff0000 <COUNT>; run flashkernel; mw.l <FB_ADDR> 0xffffff00 <COUNT>; \
       run flashrootfs; mw.l <FB_ADDR> 0xff00ff00 <COUNT>; run flashbootargs; \
       mw.l <FB_ADDR> 0xff0000ff <COUNT>; run flashlogo; \
       mw.l <FB_ADDR> 0xffffffff <COUNT>; reset
bootcmd=run stage0
```

`<FB_ADDR>` / `<COUNT>` 由真机实测填（1920×1080 ARGB8888 双缓冲 = `0x1000000` 字节 = `0x400000` 个 32-bit word）。

⚠️ 这是**候选**，不是已证。`docs/031` 的「刷机链不刷新 HDMI」若成立，`mw.l` 写了也不上屏。**必须先验证 §3 的两个未知**，否则退回 §2 方案。

---

## 4. 已被排除的路径（留痕，别重走）

| 路径 | 排除理由 |
|---|---|
| pstore/ramoops | 用户明确否定：刷前刷后都要正常系统、太复杂 |
| Android `bootanimation.zip` / `boot.mp4` / `desc.txt` 帧 | 启动链最末段（SurfaceFlinger + `/proc/msp/hifb0`），刷机阶段只有 hiboot，用不上 |
| p8 `fastplay` 分区多图 | 16 MiB 全 0、熵 0；`fastPlay` 是机制名/属性，不是分区内容 |
| p7 LOGO_TABLE 多图切换 | p7 只有**单张** JPEG（本轮实证）；11 处 `BM` 是 JPEG 流内假阳性 |
| `go <显示函数名>` 触发显示 | 显示函数名是孤立 rodata、0 指针引用（本轮 + `docs/031/037`） |
| 复杂 `if/itest` 状态机 | `itest`/`setexpr` = 0，数值分支能力弱 |
| 改 p1 二进制 | `docs/037` NO-GO（无显示载荷、`go` 路径关闭、YZC/CRC 存疑）；`docs/038` 只推翻了「不可逆」否决项，**整体 NO-GO 未解除** |

---

## 5. 落地步骤（下一步就做）

1. **先做 §2 第一版**：
   - 用 `docs/040 §5` 的点阵字体渲染器（或纯 `mw` 写色块）生成 5 张 1920×1080 阶段图，打包成 `LOGO_TABLE` 容器（复用 `scripts/make-flash-logo.py` 的 `build_table()`，改 JPEG 内容 + `LOGO_KEY_LEN`）。
   - 在 `scripts/make-community-flash-package.sh` 的 `flash.env` heredoc 里，把 `bootcmd` 改成「本阶段动作 + `flashlogo`（写阶段图到 p5）+ `reset`」。
   - `mkbootargs.py` 自动重算 CRC；出一个包，短接刷一次，**看上电后是否立刻出现第一张阶段图**。
2. 若第一阶段图能出现 → 方案成立，逐阶段补图/换色，形成完整的「刷机进度可见」包。
3. 团队 `docs/045`（原厂 p1 逆向）结论回来后，按 §3 判定能否升级成「单条 bootcmd + `mw.l` 实时换色」。

---

## 6. 验证判据（真机）

| 观察 | 判定 |
|---|---|
| 短接上电后**立刻出现**阶段图/颜色 | ✅ 进入刷机流程已可见，目标达成 |
| 阶段图随刷机推进换色/换图 | ✅ 进度可见 |
| 刷完 reset 后正常开机画面 | ✅ 收尾可见 |
| 全黑、无任何图 | 退回检查 `bootargs.bin` CRC / U 盘根文件 / 短接触发（`docs/019` 清单） |

---

## 7. 合规

- 本轮只做只读取证（命令表/关键字/哈希/分区结构核对）与方案设计；
  未刷机、未改真机、未构建镜像、未删文件、未访问项目外目录、未联网下载。
- 描述本地资源用仓库内相对路径，**不含本机绝对路径 / 用户名 / 卷名 / IP / 凭据**。
- 结论按 `docs/033 §2` 标注 `[观察]`/`[推断]`/`[未知]`；
  假阳性（`BM`、`p2` 单字符 env keys）留痕，不当证据。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
