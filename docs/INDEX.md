# 文档索引

本目录是按编号递增排列的逆向分析与实施记录。编号按时间顺序分配，**不是连续编号**：
`012`、`029`–`042`、`051`（以及 `000`）目前不存在。部分受控文件引用了这些缺失编号
（如 `040`/`041`/`042`），属于历史遗留的悬空引用，读到时按语义转到现存文档，
不要据此认为文件丢失。

## 当前入口（先读这些）

| 编号 | 文档 | 用途 |
|---|---|---|
| 053 | `053-real-hw-verify-sop.md` | 真机验证 L0/L1/L2 判据，刷机后按此记录 |
| 054 | `054-first-userspace-probe-report.md` | 6.3 用户态探针与三次死机根因（为什么必须换 7.4） |
| 055 | `055-histb-drm-backport-plan.md` | 显示/GPU 路线决策、6.3→7.4 API 差异与实测障碍 |
| 056 | `056-7.4-driver-bringup-plan.md` | **当前计划**：7.4 内核各硬件驱动移植与验证路线图 |

## 引导、刷机与回滚

| 编号 | 文档 |
|---|---|
| 001 | `001-boot-and-flash-analysis.md` — 刷机包引导/刷机机制逆向分析 |
| 003 | `003-usb-format-tool-analysis.md` — USBFormat.exe / fbinst 分析 |
| 004 | `004-hiboot-vs-uboot-analysis.md` — hiboot 与 U-Boot 差异及改用 U-Boot 的路径 |
| 006 | `006-restore-to-stock.md` — 刷回原厂完整方案（含变砖救砖） |
| 007 | `007-boot-path-analysis.md` — 启动路径专项分析（bootcmd 疑点与分阶段验证） |
| 013 | `013-no-p1-touch-plan.md` — 不动 p1 的两种方案 |
| 015 | `015-recovery-reverse-engineering.md` — 原厂 recovery 反汇编核查 |
| 018 | `018-debian-flash-guide.md` — Debian 刷机手册 |
| 019 | `019-usb-flash-checklist.md` — U 盘刷机检查清单 |
| 045 | `045-stock-boot-display-mechanism.md` — 引导程序如何绘制图像（链路坐实） |
| 046 | `046-flash-progress-display-plan.md` — 刷机阶段进度可见方案 |
| 047 | `047-p1-code-layout-for-display-re.md` — p1 代码区/数据区分离与绘制链路取证 |
| 048 | `048-sdk-boot-logo-drawing-chain.md` — SDK 源码级 logo 绘制链路 |
| 049 | `049-contact-boot-display-probe.md` — 触点引导纯显示探针 |
| 050 | `050-recovery-userland-flasher.md` — 改造原厂 recovery 用户态自动刷机（当前推荐刷机机制的来源） |

## 原厂设备与社区系统逆向

| 编号 | 文档 |
|---|---|
| 005 | `005-stock-device-analysis.md` — 原厂设备软硬件深度分析（真机采集） |
| 016 | `016-community-system-anatomy.md` — 社区 Ubuntu 刷机包解剖 |
| 027 | `027-stock-android-display-analysis.md` — 原厂 Android 显示栈静态分析 |

## Android BSP 可行性（历史调查）

| 编号 | 文档 |
|---|---|
| 008 | `008-android7-plan.md` — Android TV 7.1 移植可行性调查与计划 |
| 009 | `009-p0-android7-findings.md` — P0：MV100 的 Android 7 BSP 是否存在 |
| 010 | `010-android5-findings.md` — Android 5.x BSP 是否存在 |
| 011 | `011-android5-verification.md` — Android 5.x 资源复核与验真方法 |

## 主线内核、显示与驱动路线

| 编号 | 文档 |
|---|---|
| 002 | `002-mainline-kernel-debian-survey.md` — 主线内核 + Debian rootfs 路线调查 |
| 014 | `014-probe-net.md` — 探针的可观测信道（为什么改用网络） |
| 017 | `017-debian-ci-kernel-port-plan.md` — Debian 6.x CI 方案：内核移植/驱动/rootfs/发布 |
| 020 | `020-hdmi-display-porting.md` — HDMI 显示移植专项 |
| 021 | `021-hdmi-driver-porting.md` — HDMI 显示驱动移植专项（主线路线） |
| 022 | `022-hdmi-driver-design.md` — HDMI 驱动移植设计（SDK 源码提取结果） |
| 023 | `023-recovery-display-analysis.md` — 原厂 recovery 显示机制逆向分析 |
| 024 | `024-boot-and-display-chain-audit.md` — 启动引导 + 显示链路审查 |
| 025 | `025-mainline-display-porting-research.md` — 主线显示驱动调研（pmOS 方法论 + histb-mainline 成果） |
| 026 | `026-network-dhcp-audit.md` — 网络/DHCP 侧审计（"路由器看不到新 IP"） |
| 028 | `028-pmos-mainlining-workflow-research.md` — postmarketOS 式主线化工作流调研 |
| 043 | `043-6.3-double-buffer-fix.md` — 6.3 显示修复（P1 双缓冲保留） |
| 044 | `044-mainline-6.3-network-analysis.md` — 6.3 内核"从未连上网络"问题分析 |
| 052 | `052-mainline-kernel-vendor-driver-plan.md` — 方向调整：6.3 + backport 海思私有显示驱动 |
| 055 | `055-histb-drm-backport-plan.md` — 把 histb DRM KMS backport 到 6.3（含结论修正） |
| 056 | `056-7.4-driver-bringup-plan.md` — 7.4 内核硬件驱动移植与验证计划 |

## 维护约定

- 新文档按时间递增取下一编号，不要回填缺失编号；本文同步追加一行。
- 历史文档保留原结论，不改写；若结论被推翻，在新文档中写明"推翻了哪份文档的哪个结论"
  （例：`docs/055` §8 推翻了 §1 的"不换内核"决定）。
- 当前事实以 `README.md`、`configs/`、`patches/histb/`、CI 与 `docs/056` 为准。
