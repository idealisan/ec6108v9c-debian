# 040 — 社区 Linux 显示链路实证：写 /dev/fb0 双缓冲即可持续上屏

> 2026-11-08。用户把真机刷回社区 Ubuntu 后授权连接探索。本轮**推翻了项目里长期持有的
> 「Linux 起来后不能显示 / 只有 hiboot 静态图」的悲观判断**，给出可直接照搬到主线 Linux 的机制。
>
> 方法：通过 SSH 对**正在运行的**社区系统做只读探测 + 标准 fbdev 写接口实验；
> 不碰 `/dev/mem`（此前该探测曾导致外部 abort / 画面消失），只用 `/dev/fb0` 的
> `open/read/write/ioctl`。用户明确授权「测试系统、无数据、搞坏重刷」。
>
> 相关：`docs/023`（当年推测社区内核有 hifb/fb0 但无 fbcon、无用户态画）、
> `docs/031`（hiboot 四问）、`docs/035`（recovery 内核 MMIO 序列）、
> `docs/036`（刷机执行者）、`docs/039`（两张 logo 机制）。

---

## 0. 结论先行（决定性）

> **[观察] 社区 Linux 内核起来后，「显示」是通的**：
> Linux 用户态通过标准 `/dev/fb0` 写入像素，**能稳定上 HDMI 屏幕**。
> 之前「只显示 hiboot 静态 logo、Linux 不出画面」不是硬件/驱动不行，
> 而是**默认没有任何进程往 fb 写**、且 **fbcon 没绑到 fb0**（console 走串口）。

关键机制（本轮最大收获）：

> **`/dev/fb0` 是双缓冲 framebuffer（1920×1080、虚拟 1920×2160）。
> 只写一帧 → VO 在两帧间 flip 时，另一帧是空的 → 画面「闪一下就消失」；
> 写满两帧 → 无论 flip 到哪帧都有内容 → 持续显示。**

这一条同时解释了用户此前观察到的所有现象：
- 8 色条「闪一下」= 只写了第一帧；
- 纯红「显示不到一秒」= 第一帧有、第二帧空，flip 时隐时现；
- 写满两帧后红色/彩条「持续几秒」= 两帧都有内容。

---

## 1. 运行时环境（只读探测，2026-11-08）

| 项 | 值 | 来源 |
|---|---|---|
| 内核 | `Linux hi3798mv100 4.4.35_ecoo_81082668 SMP armv7l` | `uname -a` |
| cmdline | `model=mv100 console=ttyAMA0,115200 root=/dev/mmcblk0p9 rootfstype=ext4 rootwait blkdevparts=... mem=1G mmz=ddr,0,0,48M vmalloc=500M` | `/proc/cmdline` |
| 芯片 | `Hi3798MV100` / QFP216 / SDK `HiSTB_com_NAS_ubuntu_20220427` | `/proc/msp/sys` |
| 分区 | 9 分区（p1..p9），`root=p9` | `/proc/partitions`, `dmesg` |
| HDMI | **Sink Active / PHY Output Enable / Video Output Enable / 1080P60 / EDID Valid / TMDS 148.5 MHz** | `/proc/msp/hdmi0` |
| EDID | sink `27C1U`、Native 1080P60、HDMI1.3 | `/proc/msp/hdmi0_sink` |
| DISP1 | `1080P60/2D, VirtualScreen 1920/1080, Interface HDMI0, Zorder VIDEO->GFX` | `/proc/msp/disp1` |
| HDMI 基址 | 驱动自报 **`0xF8CE0000`**（`type 'echo help > /proc/msp/hdmi0'`） | `/proc/msp/hdmi0` |
| fb0 | `hifb`（`/proc/fb` = `0 hifb`），`/dev/fb0` | `fix.id` |
| console | **`/sys/class/tty/console/active = ttyAMA0`**；`vtcon0 = (S) dummy device` | sysfs |
| 显示进程 | **无**（dispsetting / hifb / surfaceflinger / Xorg / weston 全空） | `ps -ef` |
| 启动日志 | 仅 `HDMI kernel event(no UserCallBack): HOTPLUG`（开机 2 次，非周期性） | `dmesg` |

> **[观察]** `/proc/msp/module` 里 `HI_HDMI/HI_DISP/HI_VO` 那列 `1: ERROR` 是
> **Log Level 列**（表头 `| Module Name | ID | Log Level | Heap Memory |`），
> 不是错误状态——所有模块都一样，画面正常。按 `docs/033 §2` 第 3 条，不靠字面猜。

### 1.1 `HDMI Base Addr = 0xF8CE0000` 的意义

`docs/027 §6` 曾据 `0xf8ce0000` 常量认定「mv100 片内 HDMI TX、推翻外挂 sii9134」，
后被 `docs/029` 判为「该地址属 hi3716cv200，mv100 DT 为 `0x8ce0000`」并撤销。
本轮在**真机 mv100 运行的社区内核**里，驱动**自报使用的就是 `0xF8CE0000`**。
→ **[观察]** 至少在这套 HiSTB SDK 的运行时映射里，`0xf8ce0000` 是实际在用的 HDMI TX 基址；
`docs/029` 的 `0x8ce0000` 是 DT `reg` 相对地址，两者差 `0xF0000000`，
与 `docs/035 §5`、`docs/038` 记录的「静态映射 +`0x05000000` / DT ranges 相对地址」同类。
→ **[推断]** 不推翻 `docs/029` 的 bridge/SiI9134 结论，但**修正「`0xf8ce0000` 与本板无关」的表述**：
它是 SDK 运行时物理/映射基址，不是 cv200 专属。此项标 [存疑]，待主线 DT 映射复核。

---

## 2. fb0 几何（`FBIOGET_VSCREENINFO` / `FBIOGET_FSCREENINFO`）

用标准 ioctl 读取（sysfs 里 `bits_per_pixel=0 / virtual_size=0,0` 是 hifb 没填全，不可信）：

| 字段 | 值 |
|---|---|
| `xres × yres` | **1920 × 1080** |
| `xres_virtual × yres_virtual` | **1920 × 2160**（双缓冲，2 帧） |
| `bits_per_pixel` | **32**（ARGB8888：R@16/len8, G@8/len8, B@0/len8, A@24/len8） |
| `fix.id` | `hifb` |
| `smem_start` | **`0x3C55C000`**（=1012252672） |
| `smem_len` | **16,588,800 B** = 2 × 1920×1080×4 |
| `line_length` | **7680** = 1920×4 |

→ **[观察]** 与 `docs/023 §5.1` 当年记录的社区内核实测值
（`smem_start=0x3c55c000`、1920×1080 ARGB8888、stride 7680）**逐项吻合**，
跨会话/跨对象得到独立复核。

---

## 3. 写入实验（决定性）

全部只用 `os.open("/dev/fb0", O_RDWR)` + `os.write` / `os.read` / 标准 ioctl，
**未用 `/dev/mem`、未 mmap**（一次错误 mmap 长度 `W*STRIDE*2` 超过 `smem_len` 导致 `EINVAL`，
并疑似使画面短暂消失，已弃用该路径）。

| # | 操作 | 用户观察 | 读回验证 | 判定 |
|---|---|---|---|---|
| 1 | 写 8 色横条**仅第一帧**（8,294,400 B） | 彩条「闪一下就消失」 | — | 第二帧空，flip 时隐时现 |
| 2 | `FBIOPAN_DISPLAY` yoffset=0 | 无画面 | 第一帧读回 `0x0` | pan 后读回路径变化，非可靠判据 |
| 3 | 写纯红**仅第一帧** | 全红「不到一秒」 | t+0/+1s/+3s 第一帧均 `0xffff0000` | 显存没被清零，是显示通路 flip 掉了 |
| 4 | 后台每 0.25s 重写第一帧、跑 8s（27 次） | （未单独确认） | — | 仍未写第二帧 |
| 5 | **写满两帧全红**（16,588,800 B） | **红色持续至少几秒** | t+2..12s 两帧均 `0xffff0000` | **持续显示成立** |
| 6 | **写满两帧 8 色横条** | **彩条持续显示几秒** | t+2..10s 各色带首像素逐秒不变 | **可辨认图案也持续** |

实验 5/6 期间 `/proc/msp/hdmi0` 全程 `Sink Active / PHY Output Enable / Video Output Enable / 1080P60 / EDID Valid`，
**没有任何显示进程参与，也没有周期性 HOTPLUG 清屏**。

→ **[观察]** 结论稳固：Linux 用户态写 fb0 能上屏，且**必须写满双缓冲两帧**才能持续。
→ **[推断]** 之前「闪一下」不是被后台清屏，而是 VO 双缓冲 flip 到未写的那一帧。
→ **[未知]** 写入进程退出后画面能保持多久、是否需要持续刷新，本轮未测定（实验脚本内逐秒验证 10–12s 稳定）。

### 3.1 追加实验：用户态渲染「TTY 文字」到 HDMI（2026-11-08）

用户追加目标「要有一个 TTY 绑定到 HDMI，能看到内核启动阶段/报错」，
据此在社区真机上验证「显示文字」这一能力（详见 `docs/042`）。

只读取证（`docs/042 §1` 的条件核对）：
- `/proc/kallsyms` 里 `fbcon` 相关符号 **0 命中**；`modules.builtin` 只有
  `kernel/drivers/video/fbdev/core/fb.ko`，**没有 `fbcon.ko`**；
  `/sys/class/vtconsole/vtcon0/name = (S) dummy device`、`bind=1`；
  `/sys/class/tty/console/active = ttyAMA0`；`agetty` 跑在 `tty1` 和 `ttyAMA0`。
- 没有 `fbset`/`fbterm`/`fbi`/`setfont`/`chvt`/`openvt`，没有 PSF 字体，没有 PIL。
- → **[观察] 社区 4.4 内核编了 fbdev 核心但完全没编 fbcon，天生不具备 TTY→HDMI 能力**，
  这正是它只显示静态 logo、不出 TTY 的根因；与 `docs/042 §0` 的判断一致。

但**用户态渲染文字**不依赖 fbcon：本轮用 Python 内置 5×7 点阵字体（无任何外部库）
把 `LINUX TTY OK` / `MAINLINE HDMI 1920X1080` 渲染成 1920×1080 ARGB8888 像素，
写满 fb0 双缓冲两帧（16,588,800 B）。
→ **[观察] 写入成功**（`os.write` 返回 16,588,800 B，无错误）。
→ **[推断/待用户确认]** 若屏幕出现这两行字，则证明「在 HDMI 上显示可读文字」
  在真机上是通的，主线内核只要提供一块 framebuffer 并绑定 fbcon（P1，`docs/041`）
  即可显示 TTY——**能力侧没有障碍，障碍全在配置（`FB_BASE` / `FB_SIZE`）**。

> 区分：用户态渲染文字 ≠ 内核 fbcon TTY 绑定。前者证明「HDMI 能出字」，
> 后者才是「内核 printk / 登录提示自动上屏」（`docs/042` 的目标）。两者不混同。

---

## 4. 对项目此前结论的改写（重要）

1. **`docs/023 §5.1` 的推测被证实并细化**：社区内核确实内建 hifb、注册了 `/dev/fb0`，
   但「没有 fbcon、也没有用户态往 fb 画」——`console=ttyAMA0`、`vtcon0=dummy`、
   `ps` 无显示进程，三条硬证据齐备。所以默认画面停在 hiboot 留下的 logo。
2. **推翻「Linux 不能显示」**：那是「没人写」而非「不能写」。
   一旦有写者（哪怕是 `os.write` 一把像素），画面立刻变。
3. **`docs/020 §「刷机时背光都不亮」** 的解释仍成立（那是 U 盘刷机分支），
   但「社区系统只有静态 logo」应改述为「Linux 侧显示栈就绪但无写者」。
4. **对主线 Linux（`docs/032` 最终目标）是重大利好**：
   - HDMI PHY / VO / 时钟**由 hiboot 初始化并持续扫描**，主线内核不必重新点亮 HDMI，
     只需提供一块被 VO 扫描的 framebuffer 并让 fbcon 绑定（或 DRM/KMS 接管）；
   - `clk_ignore_unused` 保留 bootloader 显示状态这条策略（`docs/028 §5.2`）方向正确；
   - **双缓冲 + flip** 是必须满足的语义：simplefb / DRM fbdev 若只映射单帧会闪；
   - 关键缺口仍是 `docs/035 §6` 列的：fbcon/VT 绑定 + `console=tty0`、
     DRM/KMS 或 simplefb 接管、CMA 对应 MMZ、clk/reset DT 描述。
5. **与 `docs/039` 一致且互补**：p5 logo 由 hiboot 画；Linux 起来后**本可以**接管 fb0 自己画，
   社区只是选择不画。两条路径（hiboot 画 / Linux 画）用的是同一块 VO 扫描显存语义。

---

## 5. 立即可复用的「显示探针」（给主线/自测）

主线内核起来后，判定显示是否通的最小只读+写探针（不需任何显示进程）：

```python
import os, struct
f=os.open("/dev/fb0", os.O_RDWR)
STRIDE=7680; H=1080; FRAME=STRIDE*H
# 写满双缓冲两帧（必须两帧）
frame=b"".join(struct.pack("<I",c)*(STRIDE//4)*(H//8) for c in
                [0xFFFF0000,0xFF00FF00,0xFF0000FF,0xFFFFFF00,
                 0xFF00FFFF,0xFFFF00FF,0xFFFFFFFF,0xFF303030])
os.write(f, frame*2)     # 16,588,800 B
os.close(f)
```

若屏幕出现 8 色横条并保持 → framebuffer/HDMI 链路通，剩下只是 fbcon/DRM 绑定问题。
此探针可放进 rootfs 的启动脚本，作为「无串口条件下的显示自检」（`docs/028` 的 UART 替代思路）。

---

## 6. 与 `docs/038` 的关系

`docs/038` 结论：模型 A/B 不互斥，**短接（USB_BOOT=J16）走模型 B**，
`docs/037` NO-GO 的「写 p1 不可逆」否决项**可推翻**，但其余门槛（无显示载荷、
`go` 路径关闭、YZC/CRC 存疑、零写入验证未做）仍成立，**整体 NO-GO 暂不解除**。

本轮 `docs/040` 提供了一条**完全不需要改 p1** 的新路径：
既然 Linux 用户态写 fb0 就能显示，那么「让刷机过程可见」可以靠
**中间 Linux 系统往 fb0 画进度**（照 `docs/039` 的 p7 二次写分区思路，
但直接画屏而非写 logo 分区），比改 hiboot 二进制更简单、风险更低。

---

## 7. 合规

- 全程通过 SSH **只读探测 + 标准 fbdev 写**；未刷机、未改 eMMC 分区、未碰 `/dev/mem`、
  未构建镜像、未删文件、未访问本机项目目录之外的本地目录。
- 写入仅改变**运行时显存画面**（易失），不改变任何持久数据；断电/重启即恢复。
- 用户明确授权「测试系统、无数据、搞坏重刷」。
- 文档**不含本机绝对路径 / 用户名 / 卷名 / IP / 凭据**（连接信息仅存在于会话与
  本机记忆，未写入任何仓库文件）；厂商构建机标识省略。
- 结论按 `docs/033 §2` 标注 `[观察]` / `[推断]` / `[未知]` / `[存疑]`；
  「0 命中」只写「范围内未检索到」；不靠字符串/魔数推断行为。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；
  纯 `docs/` 改动不触发 build workflow。
