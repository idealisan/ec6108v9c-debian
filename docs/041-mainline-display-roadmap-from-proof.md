# 041 — 以「主线内核显示链路打通」为目标的分析与落地路线

> 2026-11-08。用户明确：**后续所有 HDMI/显示链路的探索，一律以「主线内核
> （6.x 或 7.x 皆可）显示链路打通」为目标**，不再纠结刷机可见性或改 p1。
> 本文把 `docs/040`（真机实证）与项目现状对齐，给出可执行的下一步。
>
> 相关：`docs/040`（fb0 写入实证）、`docs/035`（MMIO 序列）、`docs/029`（bridge 形态）、
> `docs/032`（主线移植纲领）、`docs/030`（HISTB 流水线）、`docs/024`（回归审计）、
> `configs/partition-layout.env`、`scripts/build-kernel.sh`。

---

## 0. 结论先行：目标可以大幅简化

`docs/040` 的决定性实证改变了主线路径的难度评估：

> **[观察]** 真机社区系统上，hiboot 已把 VO / HDMI / PHY / 1080P60 / EDID 全部初始化好，
> 且 Linux 起来后 VO **持续扫描**一块物理显存（`smem_start=0x3C55C000`，1920×1080
> ARGB8888、stride 7680、**双缓冲两帧共 16,588,800 B**）。
> Linux 用户态 `os.write("/dev/fb0")` 写满两帧即可**稳定上屏**，不需要 fbcon/VT、不需要显示进程。

→ **[推断] 主线内核要出画面，最短路径不是「自己重新点亮 HDMI」，而是「接管这块现成的显存」**：
用 `simple-framebuffer` 声明 hiboot 留下的那块内存 → `fbcon` 绑定 → `console=tty0` 出 TTY。
这绕开了 `docs/035` 的 PHY/CRG/EDID 初始化序列、`docs/029` 的发送器形态、
`media_cma`/clk/reset DT 描述等一整串难题（那些是「从零初始化」才需要的）。

**两条主线路径的新排序**（难度由低到高）：

| 路径 | 内核 | 做法 | 依赖 | 评估 |
|---|---|---|---|---|
| **P1 simplefb 接管** | 6.3 或 7.4 都行 | 声明 hiboot 显存 + fbcon | 只需**正确的显存物理地址/几何** | **推荐先做**，改动最小、可快速验证 |
| P2 DRM/KMS 全量 | 7.4 histb | VDP2 + SiI9134 + CRG + media_cma 自己初始化 | 发送器/时钟/EDID/CMA 全套 | 最终形态，但依赖多、已多次黑屏 |

> P2 仍是最终目标（`docs/032`），但 **P1 是「先让主线内核出字」的最快闭环**，
> 且 P1 成功后再上 P2 有一个已验证的显示基线做对照，排障容易得多。

---

## 1. 现状盘点（我们离 P1 差什么）

### 1.1 已经具备的（不用重做）

| 项 | 状态 | 出处 |
|---|---|---|
| `console=tty0` | **已有** | `configs/partition-layout.env:35` |
| `fbcon=map:0` | **已有** | 同上（ARM `fb_is_primary_device()` 返回 0，需 map 覆盖） |
| `CONFIG_FB` / `CONFIG_FB_SIMPLE` / `CONFIG_FRAMEBUFFER_CONSOLE` / `CONFIG_VT` | 6.3 **已开** | `configs/kernel/ec6108v9c.config` |
| 7.4 侧 `CONFIG_DRM` / `VDP2` / `SII9134` / `FBDEV_EMULATION` / `FRAMEBUFFER_CONSOLE` / `VT` | **已开** | `configs/kernel/histb-ec6108v9c.config` |
| `clk_ignore_unused` | **已有** | `partition-layout.env`（保留 bootloader 显示时钟） |
| simplefb DTS 模板 + 占位符注入脚本 | **已有** | `patches/kernel/simple-framebuffer.dtsi`、`scripts/apply-dts-placeholders.py` |
| 6.3 内置 HDMI console 驱动 | **已有**（读 VO 寄存器交接） | `patches/kernel/hi3798mv100-hdmi-console.c` |
| 显存几何实证 | **本轮刚拿到** | `docs/040 §2` |

### 1.2 关键缺口（就是这几处，别再扩散）

1. **`FB_BASE` 从未设置** → simplefb 节点**根本没生成**。
   `scripts/build-kernel.sh:83` 白纸黑字：`FB_BASE unset: framebuffer nodes omitted (safe default)`；
   CI `build-release.yml` 把 `FB_BASE` 接到 `inputs.fb_base`，但默认没给值。
   → 这是「主线内核一直没画面」的**最直接原因**，比 HDMI 驱动本身更靠前。
2. **`FB_SIZE` 写死 `0x800000`（8 MiB = 单帧）**，与 `docs/040` 实证的
   **16,588,800 B 双缓冲**不符。若只声明单帧，VO flip 到第二帧时会读到未声明内存
   → 正是「闪一下/花屏」类症状。应改为覆盖两帧（至少 `0xFD0000` ≈ 16.6 MiB，向上取整对齐）。
3. **显存物理地址需确认**：`docs/040` 的 `0x3C55C000` 是**社区 4.4 内核 hifb 自己分配的**
   MMZ 显存（`mmz=ddr,0,0,48M`），未必等于 **hiboot 留给 simplefb 的那块**。
   我们主线用的是 `blkdevparts` 8 分区 + 自己的 `mem=1G`，MMZ 布局不同。
   → **不能把 `0x3C55C000` 直接抄进 DTS**，这是 `[推断]` 不是 `[观察]`。

   **本轮追加实证（社区真机 `/proc/msp/pdm` 的 Reserve Mem Info）**：
   ```
   HIFB_DispBuf_HD   0x3f6ce000  8298496 B   IsRelease=1   (≈8 MiB 单帧)
   GFX_ZmeCoef       0x3f6ca000    12288 B   IsRelease=1
   HIFB_WBC_Buffer   0x3f534000  1658880 B   IsRelease=1
   HIFB_WBC_Buffer / baseparam 0x3fffb000 / pqparam 0x3ff7a000
   ```
   `/proc/iomem` 全区间只有 `00000000-3fffffff : System RAM`（mem=1G）。
   → **[观察]** 社区 hifb 有**多块不同的物理显存**（`0x3C55C000` 的 fb0 smem 与
   `0x3f6ce000` 的 DispBuf、`0x3f534000` 的 WBC），且都在 1 GiB DDR 顶端 MMZ 区、
   标记 `IsRelease=1`。这进一步坐实「地址不能直接抄」：连社区内核自己都有多块，
   主线内核的 MMZ/CMA 布局更不同。
   → **[推断]** `HIFB_DispBuf_HD 0x3f6ce000 / 8298496 B` 这一块尺寸正好是一帧
   （1920×1080×4=8,294,400 向上取整），很可能是 VO 实际扫描的显示缓冲；
   而 `0x3C55C000` 是 fbdev 的 mmap 基址。两者关系需真机运行时确认，
   **不据此下结论**。
4. **`FB_WIDTH/HEIGHT/STRIDE/FORMAT`** 已是对的（1920/1080/7680/a8r8g8b8），
   与 `docs/040` 实证一致，无需改。
5. **`configs/kernel/histb-ec6108v9c.config` 有个 typo**：`CONFIG_PHYSLIB=y` 应为 `CONFIG_PHYLIB=y`。
   `olddefconfig` 会忽略未知符号，不影响编译但会悄悄丢掉一个意图。顺手修。

---

## 2. 必须先做的唯一硬前置：拿到 hiboot 显存的**物理地址**

P1 成败全压在 `simple-framebuffer` 的 `reg = <BASE SIZE>` 上。这个 BASE 必须是
**hiboot 画 logo 时 VO G0 图层正在扫描的那块物理内存**。

有两条互补的取证路（都是本机可做的只读探测，不需要串口）：

- **A. 从社区真机反推（推荐）**：社区系统在线时，用 `docs/040` 的 `FBIOGET_FSCREENINFO`
  已拿到 `smem_start=0x3C55C000`。再查 VO 图层寄存器里 `G0_ADDR` 实际指向哪：
  `/proc/msp/disp1`、`/proc/msp/pdm`、以及 SDK 的 `hifb` proc（若有）。
  若 `G0_ADDR == 0x3C55C000`，说明这个地址就是 VO 扫描地址，可直接用作 P1 的 BASE 候选。
  **注意**：这是社区内核自己设的，hiboot 原始值可能不同；要交叉验证。
- **B. 从我们 6.3 驱动已有的机制读**：`hi3798mv100-hdmi-console.c` 本来就
  `ioremap(VO_REG_BASE=0xf8cc0000)` 后读 `G0_ADDR(+0x494)` / `G0_STRIDE(+0x49c)` /
  `G0_IRESO(+0x4a0)`，动态注册 simplefb。这条路**不需要预先知道地址**——
  它运行时从寄存器读。问题是 `docs/031 §3` 已证**刷机分支不写 VO 图层**，
  所以若 p1 hiboot 没在正常开机路径配置过 VO，这三个寄存器读到 0/随机，驱动会 fallback 到默认值。
  → B 的前提是「hiboot 正常开机画过 logo」，这与 `docs/039`「两张图都是 hiboot 开机画的」一致，成立。

→ **结论**：优先让 6.3 驱动**在真机跑一次并把它读到的 VO 寄存器值通过 pstore 报出来**
（pstore/ramoops 已配好，是唯一日志通道）。拿到 `G0_ADDR` 实测值后，
再决定是「用驱动动态接管」还是「用 DTS 静态声明 BASE」。这是有证据的推进，不是猜。

---

## 3. 落地步骤（按顺序，每步可验证）

### Step 1（最小、零风险）：修配置 + 让 6.3 驱动能报出实测地址
- 修 `CONFIG_PHYSLIB` → `CONFIG_PHYLIB`（7.4 config）。
- 确认 `hi3798mv100-hdmi-console.c` 会把读到的 `G0_ADDR/G0_STRIDE/G0_IRESO`
  以及 fallback 与否写进 `pr_info`（→ pstore）。若没有，补一条日志（不改逻辑）。
- 把 `FB_SIZE` 语义从「单帧 8 MiB」改为「覆盖双缓冲」（`docs/040 §3` 的教训），
  但**仅在拿到真实 BASE 后**才设 `FB_BASE`，避免声明错误地址反而更糟。

### Step 2（出包验证）：用 CI 出一个「只求显示」的最小包
- 走 6.3 `build-release.yml`（或 7.4 `build-histb.yml`），**不引入其它改动**
  （用户此前多次强调「不要额外过多修改，先刷进去试试」）。
- 用户短接刷入 → 看是否出 TTY / 绿带启动标记 → 通过 pstore 或社区 SSH 读回日志。
- 此时真机已刷回社区 Ubuntu、可正常进系统，刷我们的包失败也能用 U 盘刷回（`docs/038`
  已证实短接态走 U 盘根 `fastboot.bin`，兜底有效）。

### Step 3（按实测结果二选一）
- 若 `G0_ADDR` 读到有效地址且 simplefb 注册成功 → **P1 打通**，主线内核出字。
  之后把这个地址固化进 DTS，并补齐 fbcon/VT 绑定细节。
- 若读不到 / 花屏 → 说明 hiboot 与我们内核的显存约定不一致，退回 **P2**：
  用 `docs/035` 的 MMIO 序列 + `docs/029` 的 bridge 链路 + 7.4 的 `media_cma`
  让主线内核自己初始化显示硬件（这是最终形态）。

---

## 4. 与既有结论的关系（不改口径，只更新优先级）

- `docs/037` 改 p1 的 NO-GO、`docs/038` 模型 A/B、`docs/039` 两张 logo 机制
  —— 全部**保留**，但按用户新指令**降为支线**，不再作为主线显示工作的前置。
- `docs/035 §6` 列的「主线还差 fbcon/VT + console=tty0、DRM/KMS 或 simplefb 接管、
  CMA 对应 MMZ、clk/reset DT 描述」—— 对 **P2（从零初始化）**仍全成立；
  对 **P1（接管现成显存）**只需前两项，CMA/CRG/clk 可暂缓。
- `docs/040 §1.1` 的 `0xF8CE0000` 基址之辨保持 `[存疑]`，不影响 P1（P1 不碰 HDMI TX 寄存器）。

---

## 5. 一句话给下一步

> **先让 6.3 的 simplefb 交接驱动在真机跑一次、把 VO 寄存器实测值经 pstore 报出来**
> （同时修 `CONFIG_PHYSLIB` typo 与 `FB_SIZE` 双缓冲语义），
> 用实测地址设 `FB_BASE` 出一个最小显示包验证；出字则 P1 闭环，
> 不出则带证据转 P2 全量 DRM。这是当前以「主线内核显示打通」为目标的最短路径。

---

## 6. 合规

- 本文为分析/路线文档；未改代码、未改真机、未构建镜像、未刷机、未删文件、未联网、
  未访问本机项目目录之外的本地目录。
- 描述本地资源用仓库内相对路径，**不含本机绝对路径 / 用户名 / 卷名 / IP / 凭据**。
- 结论按 `docs/033 §2` 标注 `[观察]` / `[推断]` / `[未知]` / `[存疑]`；
  特别把「`0x3C55C000` 能否直接抄进主线 DTS」明确标为 `[推断]`，不冒充实证。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
