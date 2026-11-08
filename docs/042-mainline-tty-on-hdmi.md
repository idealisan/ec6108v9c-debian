# 042 — 主线内核：让 TTY 绑定到 HDMI，显示启动阶段与报错

> 2026-11-08。用户追加目标（承接 `docs/041`）：**要有一个 TTY 绑定到 HDMI 输出，
> 能看到内核启动时的问题、原因、阶段**。本文把「出画面」升级为「出字」，
> 列清条件、时机边界与落地步骤。
>
> 相关：`docs/040`（fb0 写入实证）、`docs/041`（主线路线图 / simplefb 接管）、
> `docs/024`（绿带标记 / 回归）、`docs/028`（pmOS 无串口的可观测手段）、
> `configs/partition-layout.env`、`configs/kernel/*.config`。

---

## 0. 结论先行：条件基本齐，但有一个时机边界必须知道

**好消息**：把 TTY 绑到 HDMI 所需的**配置和 cmdline 条件，主线两条分支基本都已具备**
（下表），差的仍然只是 `docs/041 §1.2` 那两处：`FB_BASE` 未设 → simplefb 节点没生成、
`FB_SIZE` 单帧语义。也就是说「让 fbcon 出字」和「让画面亮」是**同一个前置**，
不需要另起一套工作。

**但必须提前讲清的边界（否则落差极大）**：

> **fbcon（framebuffer console）只在 framebuffer 驱动 probe 并注册之后才绑定。**
> 因此内核**最早期**的日志（解压、`start_kernel` 前期、各子系统 `initcall` 之前）
> **不会**出现在 HDMI 上。fbcon 能显示的是「fbdev 就绪之后」的 `printk` 与用户态
> 登录提示——大约从驱动初始化阶段往后，包括大部分「哪里失败、卡在哪个服务」。
>
> 想覆盖最早期，只有三条替代路，且都受本机条件限制：
> 1. `earlycon` / `earlyprintk` —— **需要串口**，本机没有（`docs/006`、`docs/013` 硬约束）；
> 2. **pstore / ramoops** —— 已配置（`configs/kernel/*.config` 都有 `CONFIG_PSTORE_RAM`），
>    能**事后**读出早期日志，但不是实时上屏；
> 3. **绿带启动标记** —— `docs/024` 已实现（内核一进 HDMI-console initcall 就把顶部
>    240 行涂绿），它证明「内核活着并走到了显示初始化」，是**无串口下最早期可见信号**。

→ 现实目标应表述为：**「fbcon 接管之后的启动阶段 + pstore 里的最早期日志 + 绿带标记」
三者合起来覆盖「看到阶段 / 看到原因」**，而不是「从第一条 printk 起全在 HDMI 上」。

---

## 1. TTY → HDMI 所需的完整条件（逐条核对）

fbcon 把 VT 的 `tty0` 绑到某个 framebuffer，需要一条链全通：

| # | 条件 | 6.3 (`ec6108v9c.config`) | 7.4 (`histb-ec6108v9c.config`) | 说明 |
|---|---|---|---|---|
| 1 | `CONFIG_VT=y` | ✅ | ✅ | 虚拟终端 |
| 2 | `CONFIG_VT_CONSOLE=y` | ✅ | ✅ | `console=tty0` 才生效 |
| 3 | `CONFIG_VT_HW_CONSOLE_BINDING=y` | ✅ | ✅ | VT 绑定 |
| 4 | `CONFIG_FB=y` | ✅ | ✅ | fbdev 核心 |
| 5 | framebuffer 驱动 | `CONFIG_FB_SIMPLE=y` ✅ | `CONFIG_DRM_FBDEV_EMULATION=y` ✅ | 6.3 用 simplefb；7.4 用 DRM fbdev 模拟 |
| 6 | `CONFIG_FRAMEBUFFER_CONSOLE=y` | ✅ | ✅ | fbcon 本体 |
| 7 | `CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y` | ✅ | ✅ | **ARM 上 `fb_is_primary_device()` 返回 0，需覆盖** |
| 8 | cmdline `console=tty0` | ✅ (`partition-layout.env:35`) | ✅（同一 env） | 注册 VT console |
| 9 | cmdline `fbcon=map:0` | ✅（同上行） | ✅ | `__setup("fbcon=")` 设 `map_override`，把 fbcon 强制映射到 fb0 |
| 10 | **framebuffer 节点真的注册** | ❌ **`FB_BASE` 未设 → simplefb 节点被省略** | ❓ 7.4 走 DRM probe，另论 | **唯一实质缺口** |
| 11 | fb0 几何正确 | 1920/1080/7680/a8r8g8b8 ✅ | — | 与 `docs/040 §2` 实证一致 |
| 12 | 双缓冲两帧 | ❌ `FB_SIZE=0x800000`（单帧 8 MiB） | — | `docs/040 §3`：只声明单帧会 flip 到空帧闪屏 |

→ **[观察]** 1–9、11 **全部已具备**；10、12 是唯一要动的两处。
这印证 `docs/041` 的判断：**主线一直没出字，不是 fbcon/VT 没配，而是 simplefb 节点根本没生成**。

### 1.1 一个容易漏的点：fbcon 与「主设备」

ARM 上 `fb_is_primary_device()` 默认返回 0，`CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY`
会让 fbcon 找不到「主 framebuffer」而不绑定。项目早在 `partition-layout.env` 里加了
`fbcon=map:0` 正是修这个（`docs/024 §6.4` 已分析，标为候选但方向正确）。
`docs/040` 的实证（写 fb0 就能上屏）反过来说明**这块 framebuffer 是唯一的**，
`map:0` 映射到它是对的。

### 1.2 7.4 分支的差异

7.4 走 DRM，`/dev/fb0` 由 `CONFIG_DRM_FBDEV_EMULATION` 生成，其显存由 `media_cma`
（`910-02` 补丁，`0x0a000000` = 160 MiB）分配，**由内核自己初始化 VO/HDMI**，
不依赖 hiboot 遗留显存。所以 7.4 的「节点 #10」不通过 `FB_BASE`，而通过 DRM probe 成功。
`docs/041` 把 7.4 归为 P2（最终形态、依赖多），6.3 的 simplefb 接管归为 P1（最短路径）。
**对「先出 TTY」这个目标，P1 仍是更快的闭环。**

---

## 2. 能看到「哪些阶段」——诚实的分层

| 阶段 | 能否在 HDMI 上实时看到 | 手段 |
|---|---|---|
| BootROM / hiboot 画 logo | 能（静态图，`docs/039`） | hiboot |
| 内核解压 / `start_kernel` 极早期 | **不能实时** | pstore/ramoops 事后读 |
| 内核进显示 initcall（绿带标记） | **能**（绿色块 = 内核活到此处） | `docs/024` 已实现 |
| fbdev 注册成功 → fbcon 绑定 | 能（此后 `console=tty0` 生效） | 本次目标 P1 |
| 驱动 initcall / 挂载 rootfs / systemd 服务 / 登录提示 | **能**（TTY 出字） | 本次目标 |
| 内核 panic / oops 尾部 | 能（若发生在 fbcon 之后） | fbcon + pstore 双保险 |

→ 用户要的「看到问题、原因、阶段」，在 **fbcon 之后的绝大部分启动过程**能满足；
最早期那一段靠 **pstore**（已配）+ **绿带标记**（已实现）补上。

---

## 3. 落地步骤（承接 `docs/041 §3`，把「出画面」换成「出字」）

### Step 1：让 framebuffer 节点真的生成（唯一实质改动）
- 用 `docs/041 §2` 的办法拿到 **hiboot 显存物理地址**（让 6.3 驱动在真机读
  `VO_G0_ADDR`，经 pstore 报出），据此设 `FB_BASE`。
- `FB_SIZE` 从 `0x800000` 改为覆盖**双缓冲两帧**（`docs/040 §3` 实证必须）。
- 顺手修 `configs/kernel/histb-ec6108v9c.config` 的 `CONFIG_PHYSLIB` → `CONFIG_PHYLIB` typo。
- **不动** fbcon/VT/console 配置（已全对），避免 `docs/024` 警告的「在未知上叠改造」。

### Step 2：确认 fbcon 真的绑定（验证不靠猜）
主线内核起来后，通过 SSH（若网络通）或 pstore 检查：
```
cat /sys/class/tty/console/active        # 期望出现 tty0（不再是只有 ttyAMA0）
cat /proc/fb                             # 期望 0 simplefb / 或 DRM fbdev
for f in /sys/class/vtconsole/vtcon*/name; do cat $f; done   # 期望 (F) 而非 dummy
dmesg | grep -iE "fbcon|Console:|framebuffer|simple-framebuffer"
```
`/sys/class/vtconsole/vtcon0/name` 从 `(S) dummy device` 变成 `(F) ... frame buffer device`
是 fbcon 绑定的**决定性证据**（社区系统当前是 dummy，正好做反例对照，`docs/040 §1`）。

### Step 3：早期日志兜底
- 确认 pstore/ramoops 在真机能落盘（`/sys/fs/pstore/`），作为最早期日志的事后通道。
- 绿带标记（`docs/024`）保留，作为「内核走到显示 initcall」的实时可视信号。

### Step 4：出包验证
- CI 出一个「只求 TTY」的最小包（不引入其它改动，用户多次强调「先刷进去试试」）。
- 短接刷入 → 看 HDMI 是否出内核滚动文字 / 登录提示；失败可用 U 盘刷回社区
  （`docs/038`：短接态走 U 盘根 `fastboot.bin`，兜底有效）。

---

## 4. 与既有文档的关系

- `docs/041`：本文是它的细化——把 P1 的验收标准从「出画面」明确为「fbcon 出字」，
  并补齐 §1–2 的条件表与时机分层。**不改 041 的路径排序**。
- `docs/040`：提供 fb0 几何实证与「写两帧才持续」的双缓冲语义，是 `FB_SIZE` 修正的依据。
- `docs/024`：绿带标记与 `fbcon=map:0` 的由来；本文把它纳入「最早期可见信号」层。
- `docs/028`：pmOS 方法论里「无串口 → 屏幕标记 + ramoops」的三层可观测性，
  与本文 §0/§2 的分层一致。
- `docs/037`/`038`/`039`：改 p1 / BootROM / 两张 logo 均为支线，按用户新指令不占主线。

---

## 5. 一句话给下一步

> **TTY 绑 HDMI 的 fbcon/VT/console 条件主线已全部齐备，唯一缺口是 `FB_BASE` 未设
> → simplefb 节点没生成 + `FB_SIZE` 单帧。** 拿到 hiboot 显存实测地址、设对这两项，
> 出一个最小包验证 `console/active` 出现 `tty0`、`vtcon0` 变 framebuffer，
> 即可看到 fbcon 之后的启动文字；最早期日志用 pstore + 绿带标记兜底。

---

## 6. 合规

- 本文为分析/路线文档；本轮只做了 SSH 只读探测（`zcat /proc/config.gz` 不存在、
  `/sys/class/tty/console/active`、`ps`、`/dev/tty*`、本地 config grep），
  未改真机、未改代码、未刷机、未构建镜像、未删文件、未联网、
  未访问本机项目目录之外的本地目录。
- 描述本地资源用仓库内相对路径，**不含本机绝对路径 / 用户名 / 卷名 / IP / 凭据**。
- 结论按 `docs/033 §2` 标注观察/推断/未知；「最早期日志不能实时上屏」明确标出，
  不夸大能力。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
