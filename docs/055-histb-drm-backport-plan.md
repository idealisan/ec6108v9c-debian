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
