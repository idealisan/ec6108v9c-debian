# 055 — 把 histb DRM KMS 显示驱动 backport 到 6.3 内核（GPU 桌面正解）

> 2026-11-16。目标：在当前 `loonpn/ec6108v9c-linux-kernel` 6.3.0-rc5 上获得真正的
> DRM KMS 显示驱动，使 lima(Mali-450) 可经 kmsro+DRI3/PRIME 把 GPU 渲染的 GUI 桌面
> 显示到 HDMI。用户明确决定：**不切换内核大版本**（7.x 迁移风险过高），只参考
> histb-mainline 7.4 的做法，把 GPU/显示相关部分 backport 过来。

## 1. 为什么必须 backport DRM KMS（而不是继续 mmap fb0）

Mesa 官方文档（docs.mesa3d.org/drivers/lima.html）：Mali GPU 只渲染、无显示控制器，
显示需独立 display driver 经 **kmsro + DRI3/PRIME** 共享 DMA-BUF。Lima 官方已验证的
display driver 只有 sun4i-drm/meson/exynos/rockchip/tinydrm/zynqmp，**无 HiSilicon**。

现用 6.3 内核 `drivers/gpu/drm/hisilicon/` 只有 hibmc(PCIe)/kirin(手机)，**没有
hi3798mv100 的 VO 显示驱动**；显示只能走私有 fbdev + 用户态 mmap 写显存，反复触发
`Fatal exception in interrupt`（见 054 §16.8）。所以必须引入真正的 DRM KMS 驱动。

## 2. 现成来源（histb-mainline 社区，权威）

- 内核：`github.com/histb-mainline/linux` 分支 `histb`，baseline 7.4-rc2
  （commit `fd9230005e85472b81c1c7c16afe93dd878996b1`）。论坛
  bbs.histb.com/d/4770 确认 "7.3 mv100 HDMI 成功点亮"。
- 补丁：`github.com/histb-mainline/patches` 分支 `master`，quilt series。
- 已下载到本机 `TMP/histb-backport/`（未入库，含 11 个补丁，约 376 KiB）。

## 3. 需要移植的补丁清单（显示 + GPU + 依赖）

| 补丁 | 作用 | 类型 |
|---|---|---|
| `700-02` | `CONFIG_DRM_HISTB_VDP`，VDP v2 显示引擎（CRTC+primary plane，G0 图层，writeback）；`DRIVER_GEM\|MODESET\|ATOMIC` | 新增 `drivers/gpu/drm/histb/*`（~140KB）+ Kconfig/Makefile 各 1 行 |
| `700-03` | VDP v4 显示引擎（v4 变体） | 新增+改 histb Kconfig/Makefile/core |
| `700-04` | 片上 HDMI transmitter（drm_bridge/connector） | 新增+改 histb Kconfig/Makefile |
| `700-05` | MAINTAINERS 条目 | 文档 |
| `700-01` | VDP DT bindings schema | 文档 |
| `600-01` | HiSTB HDMI schema | 文档 |
| `600-02` | SiI9134 HDMI bridge（**外接桥接芯片，mv100 片上 HDMI 可能用不上，视 DTS 而定**） | 新增+改 bridge Kconfig/Makefile |
| `255-01` | `hisilicon,hi3798mv100-mali` compatible（lima probe 需要） | 文档 yaml |
| `305-01/02/03` | histb 电压 regulator 驱动（显示时钟/PHY 供电依赖） | 新增+改 regulator Kconfig/Makefile |

关键观察：**对现有文件的修改极少**（Kconfig/Makefile 各 1 行、MAINTAINERS、yaml），
主体全是新增文件 → backport 冲突面小，主要工作在新源码对 6.3 DRM API 的适配。

## 4. 6.3 vs 7.4 DRM API 差异（预研已确认，backport 核心工作）

在 6.3 内核头文件里逐个核对 7.4 驱动依赖的 API：

| 7.4 依赖 | 6.3 状态 | 适配方案 |
|---|---|---|
| `DRM_GEM_DMA_DRIVER_OPS` | ✓ 有 | 直接用 |
| `drm_bridge_connector_init` | ✓ 有 | 直接用 |
| `drm_gem_dma_helper.h` | ✓ 有 | 直接用 |
| `DRM_FBDEV_DMA_DRIVER_OPS` / `drm_fbdev_dma.h` | ✗ 缺 | 换 `drm_fbdev_generic_setup(dev, 32)` |
| `drm_client_setup.h` / `drm_client_setup()` | ✗ 缺 | 用 `drm_client_init()` + 手动 register/setup |
| `drm/display/drm_hdmi_state_helper.h` / `drm_hdmi_state_helper` | ✗ 缺（6.3 是 `drm_hdmi_helper.h`） | 删 infoframe 更新或降级到 6.3 helper |
| `drm_of_get_bridge()` | ✗ 缺 | 手写 of_graph endpoint → `of_drm_find_bridge` |
| `drm_bridge_alloc()` | ✗ 缺（6.3 用 `devm_drm_bridge_alloc` 风格/直接 kzalloc+init） | 改写分配 |
| `drm_atomic_helper_bridge_create_state/destroy_state` | 部分缺 | 用 6.3 的 `_bridge_duplicate_state` 等 |
| `drm_atomic_helper_connector_hdmi_update_infoframes` | ✗ 缺 | 删（非核心） |

工作量评估：主体 API 都有等价物，适配集中在 ~10 处。属于可控的中等规模 backport。

## 5. 还需解决的前置依赖

- **DT 节点**：histb 的 VDP/HDMI/mali DT 节点来自 `810-02`(hi3798mv100 SoC)、
  `810-03`(EC6108V9C board)、`255-01`(mali)。我们当前 DTS
  (`hi3798mv100-ec6108v9c.dts`) 是 loonpn 6.3 的版本，需把显示相关节点合入。
- **clock/reset/regulator**：VDP/HDMI 依赖 CRG clock（我们已有 hi3798 clock 驱动）
  和 `305` regulator（histb 电压驱动）。需核对 6.3 是否已有等价 regulator。
- **与私有 fbdev 共存**：启用 drm-histb 后要停掉 `hi3798mv100-hdmi-console.c` 私有驱动
  （否则两个驱动抢同一显存/VO，冲突）。simplefb/保留区机制也要相应调整。

## 6. 执行步骤（后续任务 #39）

1. 在 6.3 内核源码建工作分支，拷入 histb 新增源文件，手工加 Kconfig/Makefile 行。
2. 逐文件适配 §4 的 API 差异，用 CI 或本地交叉编译（仅编译校验，不出整包）迭代到
   `CONFIG_DRM_HISTB_VDP=y` 编译通过。
3. 合入 DT 节点（VDP/HDMI/mali），处理与私有 fbdev 的互斥。
4. 确认 `CONFIG_DRM_LIMA=m` + kmsro + X `modesetting`/DRI3 配置。
5. 本地只做轻量校验（编译、`bash -n`、DTB dtc）；**打包/出 release 走 CI**。
6. 重刷真机，验证 `/dev/dri/card0` 变为 modeset 设备、`modetest` 列出 connector、
   XFCE/glxinfo 显示 `Mali450`（非 llvmpipe）、桌面 GPU 加速显示。

## 7. 风险与护栏

- 不改内核大版本，只 backport 显示/GPU 子系统 → 避开全局回归。
- 每一步先在 CI 编译校验，不本地生成镜像（遵循项目规则）。
- 保留现有可启动版本；新内核作为独立 release 验证，失败可回退。
- 不再用用户态 mmap 写 fb0 的 hack（已证伪，见 054 §16.8）。

## 8. 动手 backport 后的实测障碍（2026-11-16，重要更新）

按用户要求实际动手 backport（不切内核版本），完成了 DRM 驱动源码适配并生成 patch
（`patches/kernel/0006-histb-drm-display-backport.patch`，`git apply --check` 通过）：
- 提取 histb 新增源码 10 个文件到 `TMP/histb-backport/extracted/`，适配 6.3 API：
  `drm_client_setup`→`drm_fbdev_generic_setup`、删 `DRM_FBDEV_DMA_DRIVER_OPS`/
  `DRM_BRIDGE_CONNECTOR`/`DRM_CLIENT_SELECTION` select、sii9134 删 7.x HDMI infoframe
  回调 + `edid_read`→`get_edid`、hi3798mv100-hdmi 的 `devm_drm_bridge_alloc`→`devm_kzalloc`。
- config fragment 已加 `CONFIG_DRM_HISTB_VDP=y`/`CONFIG_DRM_SII9134=y`，禁私有 fbdev。
- build-kernel.sh 已加 0006 patch 应用。

**但挖到依赖链底层后发现真正的阻断点（DTS/clock）**：
- histb 的 VDP/HDMI DT 节点用新 clock id（`HI3798MV100_VO_HD_CLK`=81、
  `HDMI_CTRL_CLK`=100、`HDMI_PHY_CLK`=103 等），来自 histb 500-01 新头文件（135 个 define）
  + 500-02 全新 CRG 驱动（35KB）。
- 当前 6.3 内核的 `include/dt-bindings/clock/histb-clock.h` **只有 I2C/GPU clock**，
  完全没有 VO/HDMI/VDP clock；`drivers/clk/hisilicon/crg-hi3798.c` 也不提供显示时钟。
- 因此 VDP/HDMI 驱动即便编译进内核也**拿不到显示 clock，probe 必然失败**。
- 要补齐必须 backport 整套新 CRG（500-01/02/110 系列），而当前 lima/MMC/USB 等全部
  依赖旧 CRG 才能稳定启动——替换时钟基础是高风险、牵一发动全身的改动。

**结论修正**：backport 不止是"适配 ~10 处 DRM API"，其真正成本在**替换整个 clock 子系统**。
在当前 6.3 内核上让 drm-histb 真正跑起来 ≈ 移植 histb 的 clock/reset/regulator/DTS 全套，
接近换内核的工作量，但风险更高（两套 CRG 抢同一节点）。这不是几轮 CI 能收敛的。
当前已做的 DRM 驱动 patch 适配保留在 `patches/kernel/0006-*`（可编译但未接 clock，暂不启用
config），作为后续若决定移植 clock 时的基础。

## 9. 实际 backport 实施（2026-11-16，用户坚持要做完出包）

尽管 §8 记录了 clock 深层障碍，用户明确要求"不要光说、补上 clock、做完出包"，故实际动手：

**已落地（commit ce0e8d0 → a4da46b）：**
- `patches/kernel/0006-histb-drm-display-backport.patch`：VDP v2 显示引擎 + hi3798mv100
  片上 HDMI bridge + sii9134 核心 + histb regulator（mv100 所需子集），适配 6.3 API：
  - `drm_client_setup`→`drm_fbdev_generic_setup`；删 `DRM_FBDEV_DMA_DRIVER_OPS`/
    `DRM_BRIDGE_CONNECTOR`/`DRM_CLIENT_SELECTION` select；
  - sii9134 删 7.x HDMI infoframe/atomic_create_state 回调，`edid_read`→`get_edid`
    （返回类型 `struct drm_edid *`→`struct edid *`），include `drm_hdmi_helper`；
  - `devm_drm_bridge_alloc`→`devm_kzalloc`+手动 funcs；
  - `drmm_kms_helper_poll_init`→`drm_kms_helper_poll_init`；`of_device_get_match_data`→
    `device_get_match_data`；`drmm_writeback_connector_init`→
    `drm_writeback_connector_init_with_encoder`（参数顺序适配）；
  - `.remove` 回调 void→int+return 0（core/vdp2/hdmi）。
- `patches/kernel/0007-histb-display-clock-dts.patch`：**补上了 §8 说的缺失 clock**——
  在 `histb-clock.h` 加 4 个显示 clock ID（92-95，避开现有 0-91 与 NR_CLKS=128），
  在 `crg-hi3798.c` 的 `hi3798mv100_gate_clks[]` 加 `clk_vo`/`clk_vo_hd`/
  `clk_hdmi_ctrl`/`clk_hdmi_phy` 简单 gate（寄存器 0xd8/0x10c/0x110），
  并把 VDP/HDMI DT 节点（含 of_graph port）加进 dtsi + 板级 dts 启用。
  注意：这是简化版 gate clock（不是 histb 500-02 的完整复杂 vo_hd 分频驱动），
  应能满足"clock 存在且可 prepare/enable"，VO 时序由驱动写寄存器控制。
- `configs/kernel/ec6108v9c.config`：`CONFIG_DRM_HISTB_VDP=m`/`CONFIG_DRM_SII9134=m`/
  `CONFIG_DRM_FBDEV_EMULATION=y`；保守保留私有 fbdev（probe 失败不影响启动/TTY）。
- `scripts/build-kernel.sh`：应用 0006/0007。
- `scripts/build-rootfs.sh` + `make-community-flash-package.sh`：内置 Mesa lima +
  X modesetting(DRI3/glamor) + LXDE 桌面；`IMG_SIZE_MB` 480→900（用户确认无兜底约束）。

**CI 编译迭代：** 第一轮 run 43862480515 build-kernel 失败，日志给出精确错误
（FBDEV_DMA/poll/match_data/remove），已逐项修复。新一轮 run 43864709752 进行中。

**仍需真机确认（刷入后）**：drm-histb probe 能否拿到 clock、`/dev/dri/card0` 是否变
modeset 设备、`modetest` 列 connector、X+LXDE 是否由 lima 渲染（glxinfo=Mali450），
以及简化 gate clock 是否足够点亮 HDMI。盒子在 GPU 实验后曾离线，需用户断电恢复。
