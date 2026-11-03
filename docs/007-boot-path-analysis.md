# 启动路径专项分析：原厂 hiboot 到底走不走 bootcmd

- 分析日期：2026-11-03
- 目的：回答"刷入我们的内核后，原厂 hiboot 会不会按 env 的 bootcmd 启动"
- 前提：**本机从未刷机，以下结论均为静态分析 + 待验证假设，不是实测结论**
- 相关：`005-stock-device-analysis.md`、`004-hiboot-vs-uboot-analysis.md`、`006-restore-to-stock.md`

## 1. 三个互相矛盾的启动地址

| 来源 | 命令 | 目标偏移 | 该处实际内容 |
|---|---|---|---|
| p2 存储环境（CRC 有效） | `mmc read 0 0x1FFBFC0 0x4B000 0x5000; bootm 0x1FFBFC0` | 0x4B000 = **150 MiB** | 随机数据（backup 分区内），**无任何镜像头** |
| hiboot 内置默认 bootcmd | `mmc read 0 0x82000000 0x1D000 0xC000;bootm 0x82000000` | 0x1D000 = **58 MiB** | factory 分区 |
| bootargs 的 blkdevparts | kernel 分区 | **82 MiB** | `ANDROID!` 引导镜像（实测确认） |

三者互不一致，说明**至少有两个不是实际启动路径**。

## 2. 原厂 hiboot 里的 Android 专用代码

在原厂 p1（2016 版 hiboot）中检出的字符串：

```
Enter fun Android_Main
bootcmd
mmc read 0 0x82000000 0x1D000 0xC000;bootm 0x82000000
bootimg 0x1FFBFC0
bootimg recovery/normal
ANDROID!
read misc failed
boot-recovery
find the boot-recovery flag...
enter function sw_ir_detect_recovery
[HMT] read the kernel failed.
[HMT] RSA Verify the kernel Error.
****** boot from second-recovery... ******
***** boot from first-recovery... *****
The recovery verify OK!
```

这说明原厂 hiboot 有一条**完整的 Android 启动链**：
1. `Android_Main` 入口；
2. `bootimg` 命令解析 `ANDROID!` 引导镜像（不是 uImage）；
3. 读 `misc` 判 `boot-recovery` 标志；
4. 红外按键强制进 recovery（`sw_ir_detect_recovery`）；
5. 双 recovery 兜底（first/second-recovery）；
6. RSA 校验钩子（本机 `verify=n` 未启用）。

而我们 **SDK 编译的 hiboot 里没有** `Android_Main`/`bootimg`/`boot-recovery`，
只有 `ANDROID!`（bootm 的通用格式判断），即纯 U-Boot 流程：**执行 env 的 `bootcmd` → `bootm` uImage**。

## 3. 两种可能的启动逻辑

### 假设 H1：先跑 bootcmd，失败再回退 Android_Main
- 存储的 bootcmd 指向 150 MiB（无镜像）→ `bootm` 失败 → 回退到 `Android_Main` → 启动 82 MiB 的 Android boot.img
- 若成立：我们的 env（bootcmd 指向 14 MiB 的有效 uImage）**会被执行并成功**，Debian 能启动
- 也能解释为什么 U 盘刷机脚本能跑（同一套 `run bootcmd` 路径）

### 假设 H2：正常启动固定走 Android_Main，bootcmd 只在 U 盘恢复流程中使用
- 存储的 bootcmd 是历史遗留，正常启动完全不用
- 若成立：刷完我们的包后，原厂 hiboot 仍会去 82 MiB 启动**旧 Android**（我们没覆盖那里）
  → 表现为"刷了没效果"，但**不会变砖**（因为内核/分区写入都是覆盖原 recovery/cache 区域，Android 仍能起）

两种假设下，**U 盘刷机脚本都会被执行**（否则社区方法根本不可能存在），差别只在"刷完之后能不能启动到 Debian"。

## 4. 如何用最小代价判定

### 探针包（零写入，推荐第一步）
release 中的 `mv100-mdmo1g-probe-*.zip`：只有一个 `bootargs.bin`，`bootcmd=reset`。

| 现象 | 含义 |
|---|---|
| 插 U 盘上电后盒子**立即重启/反复重启** | 原厂 hiboot 确实读取并执行了 U 盘 env 的 bootcmd（H1 成立） |
| 插 U 盘仍正常启动 Android | hiboot 未执行该 bootcmd（H2 或触发方式不对） |

拔掉 U 盘再上电即可恢复正常，全程不写 eMMC。

### 分阶段刷机（按风险从低到高）

| 阶段 | 动作 | 成功标志 | 失败后果 |
|---|---|---|---|
| 0 | 跑探针包 | 盒子重启 | 无 |
| 1 | 刷 **stock-hiboot** 包（不写 p1） | 开机进 Debian（说明 H1 成立） | 仍进 Android，无损坏 |
| 2 | 若阶段 1 仍进 Android → 刷 **sdk-hiboot** 包（写 p1） | 开机进 Debian（SDK hiboot 走 bootcmd） | 若 SDK hiboot 有问题：不启动；可用 U 盘还原包写回 p01，或串口 + HiTool |

阶段 2 的关键假设：SDK hiboot 是纯 U-Boot 流程，只要 env 的 bootcmd 正确就会跑 `bootm`。
它保留了对 U 盘 `bootargs.bin` 的支持（已确认字符串），因此即使 p1 被替换，仍可用 U 盘还原包写回原厂 p1。

## 5. 对之前结论的更正

`005` 文档曾写"社区包同款做法，历史验证可行"——**该表述不严谨**：

- "社区包可行"是社区用户的经验描述，不是本机实测；
- 社区包会**同时替换 p1**（mv100/fastboot.bin，2025 构建），其行为可能与 2016 原厂版不同；
- 因此不能把社区经验直接外推到"原厂 p1 + 我们的 env"这一组合。

本机首次刷机应按第 4 节的分阶段流程执行，并以探针结果为准。

## 6. 还原兜底（与 006 文档一致）

- 阶段 1 失败（仍进 Android）：无需还原，直接进入阶段 2 或停止；
- 阶段 2 失败（SDK hiboot 不启动）：插还原 U 盘上电，写回 p01–p15（p1 最后写）；
- 若还原 U 盘也无法触发：串口 + HiTool 烧 `p01_fastboot.img`（BootROM 下载模式）。
