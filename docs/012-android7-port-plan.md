# Android TV 7.1 移植计划（正式版）

- 分支：`android7`
- 日期：2026-11-03
- 目标：在 EC6108V9C（Hi3798MV100 / 4×A7 / Mali-450 / 1 GB / 8 GB eMMC）上运行
  **Android TV 7.1（AOSP 7.1.2 + Leanback + TIF，无 GMS）**
- 前置调查：`008`（可行性）、`009`（P0：无 7.x BSP）、`010/011`（5.x 复核与验真）

## 1. 现状盘点

| 资产 | 状态 |
|---|---|
| MV100 官方 Android SDK | **只有 4.4.2**（HiSTBAndroidV600R001C00SPC06x，已由本机 SPC065 运行 4.4.2 证实） |
| MV100 的 7.x BSP | **不存在**（GitHub 检索 HiSTBAndroidV700 = 0；V600R003 面向 mv200/mv300） |
| MV100 内核 | 官方 3.10.0_s40（4.4 版 Linux SDK 亦可编译，见 `HiSTBLinuxV100R005`） |
| 参考的 7.x 基座 | `HiSTBAndroidV600R003C00SPC0xx`（mv200/mv300，Android 7.0 时代，社区日志可见） |
| 社区 7.1 包（MV100） | 无可验证产物 |
| 硬件文档 | 有（datasheet + 兼容列表） |
| 本机备份/回滚 | 完备（p01–p16 + 还原包 + 串口救砖方案） |

**核心矛盾**：Android 7.x 的显示/视频/音频 HAL 必须与芯片 VPU/显示控制器匹配，
而这些库只随官方 BSP 提供；MV100 没有 7.x BSP，因此不存在"直接可用"的 HAL。

## 2. 三条技术路线

### 路线 A：以 V600R003（mv300 的 7.x）为基座，回移 MV100 板级

- 需要的输入：**mv300 的 V600R003 完整源码**（含 `device/hisilicon/`、HAL 源码、prebuilts）
- 工作：
  1. 保留 AOSP 7.x 框架与 mv300 的 HAL 骨架
  2. 把 `device/hisilicon/bigfish` 的板级配置指向 MV100（DDR/时钟/GPIO/IR/WiFi）
  3. 用 MV100 的 VPU/显示驱动替换 mv300 的（内核 4.4 从 HiSTBLinux SDK 取）
  4. 重新编译 gralloc/HWC/OMX 针对 MV100 的硬件
- 风险：MV300 的 HAL 大量依赖其 VPU 特性（HEVC 10bit、4K），MV100 只到 1080p，
  裁剪可行但需要逐模块验证
- 工作量：**2–4 人月**（熟悉海思平台的前提下），成功率中等

### 路线 B：纯 AOSP 7.1.2 + 自写 HAL

- 需要自己实现 gralloc/HWC/OMX/audio HAL（海思私有寄存器、私有内存布局）
- 工作量：**10 人月以上**，且硬解几乎不可能自研
- 结论：**不采用**

### 路线 C：AOSP 7.1.2 + 复用 4.4 的 vendor 库

- 4.4 → 7.x 的 HAL 接口（gralloc1、HWC 1.4、audio HAL 2.0）全部变更
- 结论：**技术上不可行**

## 3. 计划（按路线 A）

### P0 取得 7.x 源码（决定项目生死）

| 任务 | 产出 | 门槛 |
|---|---|---|
| 找 mv300/mv200 的 `HiSTBAndroidV600R003` 完整源码（论坛/网盘/镜像） | 源码树 | 能在 `device/hisilicon` 下看到 mv300 与 bigfish 配置 |
| 确认其 Android 版本为 7.0/7.1（`sdk=24/25`） | 版本证据 | 通过 |
| 确认 HAL 是否按芯片分目录（可裁剪给 mv100） | HAL 结构说明 | 有 mv100 复用空间 |

**P0 失败 → 项目终止，转备选（第 6 节）。**

### P1 基线构建（不改硬件相关）

- 用 V600R003 原样编译 mv300 镜像，确认工具链与流程可用
- 产出：可编译的基线 + 构建脚本（容器化）

### P2 内核

- 以 `HiSTBLinuxV100R005` 的 linux-4.4.y + `hi3798mv100_defconfig` 为起点
- 打开 Android 所需：binder、ashmem、ION、SELinux、cgroup、zygote 相关
- 保留 7.x 的 `binder` 协议（7.0 引入 binder 新版本，4.4 内核需 backport 或开 `CONFIG_ANDROID_BINDER_IPC_32BIT`）
- 验收：内核启动到 `init`，logcat 可用

### P3 显示与图形

- 替换 gralloc/HWC 为 MV100 版本（来源：4.4 BSP 的库 + 按 7.x 接口重写包装层）
- 验收：SurfaceFlinger 起来、1080p60 输出、桌面滑动流畅

### P4 视频硬解

- OMX 组件需 7.x 的 `ACodec` 接口；海思 4.4 的 OMX 可直接复用（OMX IL 1.1 稳定），
  主要改 `libstagefright` 侧适配
- 验收：1080p H.264/H.265 硬解，CPU < 40%

### P5 外设

- 红外遥控（键值映射到 ATV 的 D-pad/OK/Back/Home）
- RTL8188F（USB WiFi）驱动：4.4 内核源码已有，配 7.x 的 `wpa_supplicant`
- CSR8510 蓝牙：bluedroid 配置
- 以太网 PHY（`phy_addr=2,1`）

### P6 Android TV 化

- 加 Leanback Launcher、TV Settings、TIF（TvInputService 桩）
- 关闭触摸相关配置（`config_tv`），启用 D-pad 焦点模型
- 无 GMS（AOSP ATV），或使用第三方 ATV GApps（合规自担）

### P7 打包与刷机

- 复用现有引导链（hiboot + blkdevparts）与 006 回滚流程
- 产出：U 盘刷机包 + 测试记录

## 4. 工作量与风险

| 阶段 | 估时（熟悉海思平台） | 主要风险 |
|---|---|---|
| P0 | 3–10 天（找源码，可能找不到） | **最大不确定性** |
| P1 | 3–5 天 | 老工具链（python2/gcc4.x） |
| P2 | 1–2 周 | binder/cgroup backport |
| P3 | 2–4 周 | HWC 接口与显示时序 |
| P4 | 2–4 周 | OMX/stagefright 适配 |
| P5 | 1–2 周 | WiFi/BT 固件与权限 |
| P6 | 1 周 | ATV 组件裁剪 |
| P7 | 3–5 天 | 分区/回滚 |
| 合计 | **约 2–4 人月** | 成功率估计 30–50% |

## 5. 决策点（每个 Gate 不通过就止损）

1. **G0**：能否拿到 V600R003 源码（含 bigfish/mv300 板级）
2. **G1**：基线能否编译出可启动的 mv300 镜像
3. **G2**：MV100 内核 4.4 能否启动到 Android init
4. **G3**：显示（SurfaceFlinger）能否跑起来
5. **G4**：硬解能否工作
6. **G5**：遥控/网络可用
7. **G6**：ATV 桌面可用

## 6. 备选（任一 Gate 失败）

1. **保留 Debian**（现有方案，媒体中心可用）
2. **换硬件**（S905X3/X4，ATV 9/11，成本 ~200-300 元）
3. 接受 4.4 盒子 ROM（当贝桌面），解决"IPTV 限制"但解决不了新 App 兼容

## 7. 立即行动（本周）

1. 在论坛/网盘检索 `HiSTBAndroidV600R003` 完整包（关键词：mv300 SDK、hi3798mv300 android 7 源码）
2. 若能拿到：先跑 `scripts/inspect-rom.sh` 验版本，再解压确认 `device/hisilicon` 结构与 HAL 目录
3. 同步准备构建容器（Ubuntu 18.04 + python2 + gcc4.9 交叉工具链）
4. 结论写入 `012` 文档的"执行记录"小节
