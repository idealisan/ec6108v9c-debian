# Android TV 7.1 移植可行性调查与计划

- 分支：`android7`
- 日期：2026-11-03
- 目标设备：EC6108V9C（Hi3798MV100，4×Cortex-A7 1.5 GHz，Mali-450，1 GB DDR3，8 GB eMMC，RTL8188F WiFi，CSR8510 BT）
- 目标系统：原生 Android TV 7.1（AOSP 7.1.2 + Leanback Launcher + TV Input Framework，无 GMS 或第三方 ATV GApps）

## 1. 结论先行

| 判断 | 依据 |
|---|---|
| 官方 BSP 无 MV100 的 7.x | 海思 Android SDK 命名 HiSTBAndroid V5xx≈4.4、V6xx≈5.x、V7xx≈7.x，但公开渠道只见 V500/V600 覆盖 hi3798mv100，V700 主要面向 mv200/mv300 |
| 社区有 7.1 的"盒子固件" | 论坛（ZNDS、智能电视网等）有 hi3798mv100 的 7.1.2 刷机包，但多为**当贝桌面风格的盒子 ROM**，不是 Android TV；来源与真实性参差 |
| "原生 Android TV" 与"盒子 ROM"差距大 | ATV 需要 TIF、Leanback、TV Settings、D-pad 导航、无触摸；盒子 ROM 只需桌面可用 |
| 纯 AOSP 7.1.2 + 4.4 的 vendor 库不可行 | 4.4→7.x 之间 gralloc/HWC/OMX/audio HAL 接口大改，没有对应 BSP 就无硬件加速与视频解码 |
| 可行路径只有两条 | A：找到真正的 MV100 7.x BSP/ROM 做二次开发；B：以 V700（mv200/300）为基座回移（工程量极大） |

**因此本计划的核心不是"立刻编译"，而是先做 P0 可行性验证**，用明确的判定门槛决定是否继续。

## 2. 技术约束

### 2.1 硬件

| 部件 | 约束 |
|---|---|
| GPU | Mali-450 MP（Utgard），Android 7 需要对应 r6p0/r7p0 DDK + gralloc；8.0 之后无官方更新 |
| 视频 | 海思 VPU + 私有 OMX 组件（H.264/H.265 硬解），必须与 Android 版本匹配 |
| 内存 | 1 GB：ATV 7.1 系统本身占 500–650 MB，需精简或换 Launcher |
| 存储 | 8 GB：ATV 7.1 system 约 800 MB–1.2 GB，data 需 2 GB+，空间紧张但可行（需重新划分） |
| 无线 | RTL8188F（USB 2.4G），驱动为 Realtek 私有，7.x 需重新编译/适配 |
| 蓝牙 | CSR8510（USB），Android 7 需 bluedroid 适配 |
| 遥控 | 红外 + 面板键，键值需重新映射到 ATV 输入规范 |

### 2.2 软件栈（Android 7.1 必需）

- 内核：3.10 可用但需 backport（Android 7 官方推荐 3.18/4.4；3.10 需补 `binder`/`ashmem`/SELinux 更新）
- HWC：7.x 用 HWC 1.4/1.5（HWC2 是 8.0），海思私有 hwcomposer 必须提供 7.x 版本
- gralloc：ION + 私有格式，需匹配 7.x 的 `gralloc1` 接口
- 媒体：OMX IL 需支持 7.x 的 `ACodec` 变更
- 音频：tinyalsa + 私有 audio HAL（4.4 的 HAL 是 `audio_hw` 旧接口）
- ATV 框架：TIF（`android.media.tv`）、Leanback、TV Settings，需要设备具备 tuner/HdmiInput 或至少 input framework 桩

## 3. 三条候选路线

### 路线 A：基于现成 MV100 Android 7 ROM 二次开发（推荐先验证）

- 前提：能拿到**确实基于 Hi3798MV100** 的 7.1.2 固件（非 MStar/Amlogic 混淆）
- 工作：
  1. 解包 system.img，确认 `ro.board.platform`、内核版本、HAL 库（`libgralloc`、`libOMX`、`hwcomposer`）
  2. 若 HAL 与 MV100 匹配，替换为本机适配：分区表、遥控键值、WiFi/BT 驱动、显示输出
  3. 加入 ATV 组件（Leanback、TV Settings、TIF 桩）或直接采用带 ATV 桌面的 ROM
- 优点：周期最短（天～周级）；缺点：ROM 质量与可持续性依赖上游

### 路线 B：以 HiSTBAndroid V700（mv200/300）回移到 MV100

- 工作：内核 3.10→4.4 升级、DDR/时钟/VPU 驱动回移、HAL 适配、分区重构
- 优点：可控、可维护；缺点：工程量以"人月"计，且缺少 MV100 的 4.4 内核基线

### 路线 C：AOSP 7.1.2 通用 + 现有 4.4 vendor 库

- 结论：HAL 接口不兼容，不可行（仅作排除项记录）

## 4. 分阶段计划（每阶段有明确验收门槛）

### P0 可行性验证（1–3 天，无风险）

| 任务 | 产出 | 门槛 |
|---|---|---|
| 收集 MV100 7.1 固件样本（论坛/网盘），核验真实芯片 | 固件清单 + 芯片/内核标识 | ≥1 个确认基于 hi3798mv100 的 7.1.2 |
| 反向检查其 HAL（gralloc/HWC/OMX/audio）版本 | 库清单与接口版本 | 能对上 7.x 接口 |
| 确认是否含 ATV 组件（Leanback/TIF） | 组件清单 | 有或可加装 |
| 评估 8 GB eMMC 分区方案 | 分区表草案 | system≥1.2 GB、data≥2 GB |

**P0 不通过 → 终止 7.1 移植，转入备选方案（见第 6 节）。**

### P1 环境与源码（若 P0 通过）

- 搭建 AOSP 7.1.2 或厂包编译环境（Ubuntu 18.04/20.04 容器）
- 建立分支内目录：`android7/{rom,boot,hal,notes}`
- 产出：可重复的编译脚本 + 基线镜像

### P2 引导与分区

- 复用既有成果：hiboot（U-Boot 3.3.0）引导 boot.img，分区由 `blkdevparts` 定义
- 设计 Android 布局：`fastboot / bootargs / kernel / recovery / system / cache / data`（对齐 8 GB）
- 验收：能进 recovery、能挂载 system/data

### P3 显示与图形

- 验证 HWC / gralloc / SurfaceFlinger 正常、分辨率 1080p60 输出
- 验收：桌面流畅（≥30 fps）、无撕裂

### P4 视频硬解

- 验证 OMX H.264/H.265 1080p 硬解
- 验收：4K 可降级到 1080p 硬解，CPU 占用 <40%

### P5 外设

- 遥控键值映射（D-pad/OK/Back/Home）、WiFi（RTL8188F）、BT（CSR8510）、以太网
- 验收：ATV 遥控全键可用、WiFi 可连、有线可通

### P6 Android TV 框架

- Leanback Launcher、TV Settings、TIF 桩、D-pad 焦点模型、无触摸配置
- 验收：可用遥控完成首次开机设置与日常操作

### P7 打包与刷机

- 生成 U 盘/HiTool 包；沿用 006 的还原链路
- 验收：可重复刷入并可回滚

## 5. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| 找不到真正 MV100 的 7.x BSP | 路线 A 直接失败 | P0 硬门槛，尽早止损 |
| HAL 版本不匹配 | 无 GPU/无硬解，体验不可用 | P0 阶段检查库接口 |
| 1 GB 内存不足 | ATV 卡顿、后台被杀 | 精简系统、换轻量 Launcher |
| 8 GB 存储不足 | system+data 挤爆 | 重新分区、精简 preload |
| GMS/ATV 授权 | 不能预装 Google 服务 | 无 GMS 方案（AOSP ATV）或第三方包 |
| 刷机变砖 | 设备不可用 | 已有全量备份 + 006 还原流程 |
| 与 Debian 分支冲突 | 分区布局互斥 | 两个分支各自定义布局，切换需重刷 |

## 6. 备选方案（若 P0 不通过）

1. **保留 Debian**，在 Debian 上跑 Kodi/VLC 等媒体中心（已是现成方案）
2. 购买现成 Android TV 盒子（S905X 系列，7.1/9.0 生态成熟）
3. 用社区 7.1 盒子 ROM（当贝桌面风格）满足"新软件兼容"需求，接受它不是 Android TV

## 7. 与现有分支的关系

- `main`：Debian 方案（已可构建、待真机验证）
- `android7`：本计划与后续 Android TV 移植
- 两支共用：`docs/001`（引导/分区）、`docs/005`（原厂分析）、`docs/006`（回滚）、`docs/007`（启动路径）

## 8. 立即可做的下一步

1. 收集 3–5 个声称支持 hi3798mv100 的 7.1 固件，逐个解包核对芯片标识与 HAL 版本（P0 核心）
2. 同时确认本机 eMMC 8 GB 下的 ATV 分区可行性（system/data 空间测算）
3. 若 P0 通过，再决定是"改现成 ROM"还是"V700 回移"
