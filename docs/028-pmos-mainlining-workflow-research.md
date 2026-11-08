# 028 — postmarketOS 式主线化工作流调研（方案与技术储备）

> 目的：为「若当前 hiboot framebuffer 交接路线最终不通，就基于原厂安卓系统
> 重写/移植显示驱动」这条 plan B 预先储备方法论与技术方案。
> 本文是**调研报告**，不是实施计划；触发条件见 `MAINLINE-PORTING.md`。
> 当前主线仍在 6.3-rc5，未切换内核。

---

## 0. 结论摘要

1. postmarketOS 的 mainlining 不是「把安卓驱动搬过来」，而是**以 vendor
   (downstream) 内核为只读参考**，提取硬件行为，再用 mainline 的子系统
   （DRM/KMS、clock、reset、regulator、CMA、DT binding）重新实现。
2. **第一优先级不是显示，而是「拿到设备反馈」**：UART > simple-framebuffer >
   ramoops（官方称 ramoops 是 last resort）。本机**没有串口硬件**，等于被
   直接推到最难的第三档，这解释了为什么我们这几轮这么吃力。
3. 官方与多个实战案例反复强调的两条，恰好**逐字印证我们已有的判断**：
   - 复用 bootloader 留下的 framebuffer 时，`reserved-memory` 节点**必须带
     `no-map`**，否则 `ioremap` 引发冲突甚至 kernel panic（见 §5.1）。
   - 显示时钟控制器（dispcc）必须禁用 / `clk_ignore_unused`，否则内核
     初始化时钟会重置 bootloader 设好的状态，导致画面死掉（见 §5.2）。
4. 对我们最省力、也最符合 upstream 方向的做法，不是把私有驱动移植到 6.3，
   而是**直接采用 `histb-mainline` 已在 7.3 上点亮 mv100 HDMI 的成果**
   （2026-10，实验硬件包含 EC6108V9C，见 §6）。这也回答了 `docs/025` §8
   里「反向移植到 6.3 更重」的判断。
5. 论坛实测明确指出：**需要在 cmdline 加 `console=tty0` 才能在屏幕上看到
   dmesg** —— 我们已经有这一项。

---

## 1. 核心概念

| 术语 | 含义 |
| --- | --- |
| downstream / baseline kernel | 厂商随安卓设备提供的内核 fork（我们的是 HiSTB SDK 4.4 + 私有 MPP/HIFB 栈），与 kernel.org 的上游差异巨大 |
| upstream / mainline | kernel.org 的官方内核，目标是用一套共享内核包支持多设备，不再维护 fork |
| mainlining | 让设备能用 upstream 内核启动的过程；「能启动、其它都不工作」就已经算重大成果 |
| continuous splash | bootloader 初始化显示后不熄屏，把 framebuffer 交给内核继续用；simplefb 正是靠这个 |
| pinned driver | 与厂商 BSP API / 用户态 blob 强绑定的驱动（GPU、VPU、ISP），mainline 往往没有等价物 |

postmarketOS 的动机不是兼容性而是**可持续性**：fork 无法持续获得安全补丁。
这与我们的目标（让盒子长期跑一个能维护的 Debian）一致。

---

## 2. 前置条件（官方 Mainlining Guide）

- 已有基于 downstream 内核、能进 shell 的移植（**我们已有**：社区 Ubuntu + SSH）。
- 调试通道：**推荐串口**；没有串口时可用 framebuffer console（需在 DTS 启用）
  或 ramoops 拿日志。
- 内核打包：pmOS 不再把 DTB append 到 kernel image，而是把 dtb 放在
  `/usr/share/dtb`，由 `postmarketos-mkinitfs` 按 deviceinfo 拼接。
  （**注意**：我们当前刻意用 `CONFIG_ARM_APPENDED_DTB` + uImage，属于 hiboot
  引导链约束，不能直接套 pmOS 打包方式。）
- 固件配合问题：bootloader / trustzone 常需要 mainline 不接受的 ugly hack，
  社区用二级引导（如 `lk2nd`）绕过。本项目有 U 盘 hiboot 通道，属同类思路。
- 工具：`pmbootstrap`（含 `envkernel.sh` 自动配交叉工具链）、
  `mainline-tools`（`mb` 构建 / `mp` 打包 boot.img / `mf` 刷入）、
  initramfs 加 `debug-shell` hook。

---

## 3. 标准工作流（分阶段，逐步验证、不要跳步）

1. **确认 SoC 在 mainline 有支持**；没有则先找同 SoC 的活跃开发树
   （我们对应 `histb-mainline/linux`）。
2. **建立反馈闭环**（最重要）：先让任意一种日志通道可用，再动其它。
   原则是「**The less you add, the easier it is to debug what broke**」——
   DTS 从最小集开始，每加一个节点都验证一次。
3. **准备 DTS**：以 SoC 的 `dtsi` 为基础复制板级 DTS，从下游 DTS 里取
   regulator 电压、GPIO、时钟、内存保留区等值；逐个注释掉暂不需要的节点
   （GPU、MDSS、remoteproc、 modem 等），避免它们抢显示或让启动挂住。
4. **用 downstream 内核源码做参照**：board file / defconfig / DT / 寄存器
   定义。board schematics 用于校验下游 DTS 里被错误建模的部分
   （例如把固定 regulator 画成 enable GPIO）。
5. **先让 simple-framebuffer 出字**（见 §4），此时屏幕可用、能读日志，
   但还没有真正的显示驱动。
6. **再写显示驱动**：panel / bridge / DRM KMS（见 §5、§7）。
7. **逐子系统推进并测试**：每个子系统迁移后跑集成测试再进下一个；
   用 `git diff bsp..mainline -- drivers/<subsys>/` 看差异，把补丁分成
   「已废弃 / 需移植 / 需拆分 upstream」三类；用
   `scripts/get_maintainer.pl` 找子系统 maintainer；对照
   `Documentation/devicetree/bindings/` 确认 DT 契约变化。
8. **双树并行 + 单向迁移**：冻结的 BSP 树继续出货，mainline port 树做开发；
   只把关键修复从 BSP 反向移植到 port，不把新特性搬回 BSP；两棵树都跑 CI。
9. **upstream**：按 subsystem 拆补丁送 LKML，避免与其它人重复。

> BSP→mainline playbook 给的时间尺度是 6 个月量级、按子系统分 6 个阶段，
> 并明确列出「不要迁移」的条件（含「关键硬件无 mainline 驱动且写不出来」）。
> 对我们的启示：整套重写成本很高，**优先复用已有上游成果**。

---

## 4. 调试反馈通道（本机受限的关键点）

官方 `Qualcomm mainline porting` 给出的三档，按可靠性排序：

| 通道 | 说明 | 本项目 |
| --- | --- | --- |
| UART | 最有用，能拿早期内核与 bootloader 日志 | **无串口硬件，排除** |
| Simple Framebuffer | 前提是 video-mode panel 且 bootloader 留下 continuous splash 的 framebuffer；能在写 panel 驱动之前就用屏幕看日志 | **我们正在做的路线** |
| RAM Console / ramoops | 官方原话「more of a last resort… unreliable and in many instances quite difficult」 | 已通过 `ramoops.dtsi` 激活，作为唯一存活日志通道 |

也就是说：**我们一上来就被迫用 pmOS 认为最难、最不可靠的那一档**。
这不是方案选错，而是硬件约束（无串口）。因此阶段 logo、绿带标记这类
「把状态画到屏幕上」的手段，本质上是在**补造一个 UART 替代品**，
方向是对的，应继续强化。

---

## 5. 已被外部资料印证的两条硬约束（重点）

### 5.1 `no-map` 是 simplefb 能否工作的前提

多个独立来源一致：

- SDM845 Mainlining / Qualcomm 案例：找到 bootloader 的
  `Display Reserved` / `cont_splash_region` 地址后，创建
  `simple-framebuffer` 节点**同时必须拷贝对应的 `reserved-memory` 节点**。
- OnePlus Nord N10 实战：`cont_splash_region` 地址来自下游 DT，
  并把 bootloader-log / param / mtp 等区域从内核内存里 carve out，
  防止内核 clobber bootloader 依赖的内存。
- 一篇 quirky bootloader 的主线化记录说得更直接：
  > "Also make sure to put `no-map` in the cont-splash node in the reserved
  > memory region, **or else it won't work** (non-fatal kernel panic
  > pertaining to ioremap)."

**这直接印证 `docs/024` §6.3 疑点 2、§6.4 的下一步判断**：我们
`FB_BASE` 为空时只注入 ramoops，显存没用 `no-map` 从内核 RAM 排除，
`simplefb_probe()` 的 `ioremap_wc()` 与内核线性映射属性冲突，
很可能就是「绿带能显示、fbcon 文字不出现」的根因。

→ 具体行动（已写在 `docs/024` §6.4）：从 pstore 读出驱动打印的
`VO layer0: addr=0x...`，把该地址作为 workflow 已有的 `fb_base` 输入
重新发版，让 `apply-dts-placeholders.py` 注入带 `no-map` 的 `fb_mem`。
**这一步不需要走 pmOS 重写驱动**，应优先做完再谈 plan B。

### 5.2 显示时钟必须留着 bootloader 的状态

- SDM845 案例：显式 `&dispcc { status = "disabled"; }` 与
  `&gpu { status = "disabled"; }`，原因是
  > "If the display clocks initialise then it will reset the states set up
  > by the bootloader and cause the display to die."
- OnePlus Nord N10：同样显式禁用 dispcc，否则屏幕刷新抖动、控制台不稳。

**印证我们的 `clk_ignore_unused`**（`configs/partition-layout.env` 里有，
注释已说明用途）。这条在切换内核/重写驱动时必须保留，否则会重现
「驱动一 probe，画面就黑」。

---

## 6. HiSilicon / mv100 上游现状（2026-10–11，重要）

调研到的最新事实，直接改变 plan B 的成本估算：

- **2026-10-05**：社区（Ggthifb）宣布在 **Linux 7.3 主线**上成功点亮
  mv100 HDMI 输出，并明确「需要在 cmdline 添加 `console=tty0` 才能在
  屏幕上看到 dmesg」。随后完成 HDMI，转向硬编解驱动。
- **2026-10-28**：各 SoC 工作统一到 `histb-mainline` 组织，基于最新 7.3，
  「基本硬件和 HDMI 输出都能工作」，**实验硬件明确包含 EC6108V9C 与
  HC2910**；不再默认提供预编译内核。
- `histb-mainline` 组织下有 `linux`（fork 自 torvalds/linux）、
  `patches`（out-of-tree 补丁，2026-11-05 仍活跃）、`histb-stage1`、
  `hiloot`、`arm-trusted-firmware` 等仓库；另有论坛页集中记录引导方式。
- **LKML 已有上游补丁**：David Yang (`mmyangfl`) 的
  `regulator: histb: add voltage regulator driver` v2（2026-10-09），
  覆盖 hi3798cv200/mv100/mv200 等 —— 说明该 SoC 的驱动正在被逐个
  正式 upstream，而非只停留在 fork。
- 讨论里明确 mv100 是 **Cortex-A7**、mv200 之后是 A53，架构差异大；
  `hi3798cv200` 海思自己已上游化。

**结论**：`docs/025` §8 的结论（把 7.4 显示补丁反向移植到 6.3 更重）
依然成立，而且现在有更强的替代项——**直接采用已在同一块
EC6108V9C 上验证过 HDMI 的 7.3 主线树**，比自己重写驱动更快、也更
符合 upstream 方向。用户已 fork 了 patches 仓库作为可选载体。

---

## 7. 从 vendor 驱动提取硬件行为的手法（plan B 真正要用时）

团队成员对原厂分区备份的静态逆向（`docs/027`）已经产出符号与寄存器
证据。若走到「重写驱动」这一步，下列是社区通用的补充手法：

| 手法 | 用途 | 出处 |
| --- | --- | --- |
| 修改下游安卓内核加 `printk`，打印初始化时发出的命令/寄存器序列，再与主线驱动逐条对比 | 拿到「正确的寄存器写入顺序」 | Qualcomm mainline porting（`dsi_panel.c` 加 dump 的示例 patch） |
| `mmiotrace` 完整记录驱动所有 MMIO 读写（带时间戳、可注入 marker） | 定位初始化顺序问题、某寄存器被旧值覆盖 | nouveau / freedesktop MmioTrace、内核 `Documentation/trace/mmiotrace.txt` |
| `devmem` 运行时读写物理寄存器 | 「看硬件到底收到什么」、绕过驱动二分法验证时钟/电源域 | Linux 显示驱动调试指南 |
| `ftrace` / `trace-cmd` 追踪函数调用 | 确认代码路径是否走到、分支是否命中 | 同上 |
| `modetest` 模式切换 + vblank 验证 | 改完驱动后自动化验证，替代「肉眼盯屏幕」 | 同上 |
| 从下游 DT 生成 panel 驱动（`mdss dsi panel driver generator`） | 常常生成后即可工作 | Qualcomm mainline porting |
| 反汇编 / 十六进制对比不同配置下的寄存器 dump | 找出控制位含义（分辨率、电源、 detection） | ms912x Register Analysis Tools |

**「Trojan Horse」技巧**（Sony Xperia 5 II 完整工程日志）值得记下：
bootloader 已经把 panel 初始化好、显示本来就亮着，但 DRM 驱动因为没有
panel 节点、bridge chain 不完整而 probe 失败（`-ENODEV`），GPU 也起不来。
做法是塞一个 `compatible` 匹配的**假 panel 节点**让 bridge chain 闭合，
初始化序列即使略有偏差也会被已点亮的屏幕无害地吸收。
→ 这与我们「借 hiboot 留下的显示状态」的思路同源，若将来接 DRM，
这是避免重做初始化的现成套路。

### DRM/KMS 目标模型（重写驱动时的落点）

`framebuffer → plane → CRTC → encoder → bridge → connector/panel`。
atomic modeset 把状态拆成 `drm_plane_state` / `drm_crtc_state` /
`drm_connector_state`，先校验再一次性提交；共享时钟等资源用
`drm_private_obj` 建模。写驱动时应拆成 plane / CRTC / bridge / connector
分别实现，而不是一个巨石模块。

---

## 8. 映射到 EC6108V9C 的建议路线（储备，非立即执行）

按成本从低到高，**前面的没验证失败之前不要跳到后面**：

1. **先补 `no-map`**（§5.1）：仍在 6.3，用 `fb_base` 输入发一次版。
   这是最便宜、且被外部资料反复点名的修复。
2. **保留并强化屏幕可见标记**（阶段 logo、绿带）：在无串口条件下，
   它们等价于 UART，是后续一切调试的地基。
3. **若仍不通，评估切 `histb-mainline` 7.3 树**（§6）：同 SoC、同板型、
   已点亮 HDMI，比自己重写驱动划算；代价是迁移 DTS/cmdline/分区布局与
   重新打通刷机链。
4. **最后才做「基于原厂安卓重写显示驱动」**：以 `docs/027` 的静态逆向 +
   §7 的动态 trace 为输入，按 §3 的逐子系统流程推进，目标形态是
   DRM/KMS bridge/panel 驱动（§7 末）。
5. 全程保留：U 盘 hiboot 救援通道、p1 不写、`clk_ignore_unused`、
   pstore/ramoops、p2/DTB 单一来源 cmdline。

### 与 pmOS 标准流程的差异（必须记牢）

| pmOS 典型 | 本项目 |
| --- | --- |
| 有串口 / 可加 `lk2nd` 二级引导 | 无串口，hiboot U 盘刷机是唯一底层通道 |
| DTB 单独存放、由 mkinitfs 拼接 | `CONFIG_ARM_APPENDED_DTB` + uImage，DTB 自带 cmdline 且覆盖 bootloader |
| 目标是手机 panel/DSI + 电池/触屏 | 目标是 HDMI 输出（TV），无 panel、无电池 |
| Alpine + pmbootstrap 打包 | Debian armhf + CI 出 sparse ext4 刷机包 |
| 可用 USB gadget 网络拿 SSH | 依赖有线 FEMAC DHCP（已加固 `net.ifnames=0` 等） |

---

## 9. 与既有文档的关系

- `MAINLINE-PORTING.md`（`mainline-porting` 分支）：plan B 工作区与触发条件。
- `docs/025` §8：反向移植 histb 7.4 补丁到 6.3 的评估 → 本文 §6 补充了
  2026-10 的最新上游进展，结论更偏向「直接采用已验证的 7.3 树」。
- `docs/024` §6.3–6.4：B 分支根因与 `fbcon=map:0` 候选修复 → 本文 §5.1
  为 `no-map` 疑点提供了外部印证。
- `docs/027`（团队研究中）：原厂分区备份静态逆向 → 本文 §7 是其动态
  手法的补充。
- `docs/021`/`022`/`023`：SDK 寄存器序列、原厂 recovery 显示逆向 →
  与 pmOS「以 downstream 为只读参考」的方法一致。

---

## 10. 参考（公开资料）

- postmarketOS Wiki — Mainlining Guide: https://wiki.postmarketos.org/wiki/Mainlining_Guide
- postmarketOS Wiki — Qualcomm mainline porting: https://wiki.postmarketos.org/wiki/Qualcomm_mainline_porting
- postmarketOS Wiki — SDM845 Mainlining: https://wiki.postmarketos.org/wiki/SDM845_Mainlining
- Mainlining OnePlus Nord N10 5G — Part 1: https://danascape.github.io/posts/billie-mainline-1
- BSP → mainline migration playbook: https://dangvitin.github.io/linuxlearn/part8-debug/ch122A-bsp-mainline-migration.html
- Sony Xperia 5 II (pdx206) 完整工程日志: http://onlybits.org/terminal-index/pdx206-mainline
- quirky bootloader 主线化记录（含 no-map 与 simplefb 节点示例）: http://gist.githubusercontent.com/TheSithLordDarthImperivious/6956b95de36442ddec2a18bad05d31bb
- Linux 内核文档 — KMS: https://kernel.org/doc/html/v6.0/gpu/drm-kms.html
- GPU Driver Developer's Guide: https://docs.kernel.org/7.1/gpu/index.html
- MmioTrace（freedesktop）: https://people.freedesktop.org/~mslusarz/nouveau-wiki-dump/MmioTrace.html
- ms912x Register Analysis Tools（逆向工具实例）: https://deepwiki.com/rhgndf/ms912x/4.2-register-analysis-tools
- Linux 显示驱动调试指南（devmem / mmiotrace / ftrace / modetest）: https://kwkr.cn/news/583866
- HiSTB 社区 — Linux 7.3 mv100 HDMI 点亮: https://bbs.histb.com/d/4770/6
- HiSTB 社区 — histb 主线内核汇总: https://bbs.histb.com/d/4805/1
- histb-mainline 组织: https://github.com/histb-mainline
- LKML — regulator: histb (David Yang, 2026-10-09): https://patchew.org/linux/20261009214404.722628-1-mmyangfl@gmail.com/
