# mainline-porting 分支：postmarketOS 式移植工作区

> **状态：已启动（2026-11-08）**。用户决定开始走 plan B，本分支成为该项工作的
> 主工作区。已从 `main` merge 全部调研文档与既有改动（`f85f454`）。
> `main` 仍保留 6.3-rc5 刷机链（独立 `build-release.yml`），两边互不阻塞。
>
> **基线已定为 B（HISTB 上游 Linux 7.4-rc1 + quilt 补丁集）**，并已新建独立
> `.github/workflows/build-histb.yml`——只监听本分支，push 即构建、自带
> `histb-$STAMP` release，无需合并到 main。详见 **`docs/030`**。
> 首次 CI 验证尚待跑；显示驱动正确性不是这一阶段的目标，先打通链路。

---

## 0. 为什么走到这一步

`main` 上的 HDMI 路线是「**借** hiboot 留下的 framebuffer」：hiboot 初始化
VO / VDP / HDMI TX / PHY 并画 p5 logo → `hi3798mv100-hdmi-console.c` 读 VO
`G0_ADDR` → 注册 `simple-framebuffer` 让 fbcon 打日志。这是**交接**而非驱动，
完全依赖 bootloader 残留状态。

实际经过（时间线，见 `docs/024` §6 / §6.5）：

- 134943Z：能看到 "Debian Linux" logo，但无内核日志、无 IP。
- 153551Z：把 `bootcmd` 从 `;` 改为 `&&` 串联 + 每步写 stage 图到 p5，
  结果**连 hiboot 开机画面都全黑**。复盘发现该厂商 hiboot 无 `&&` 解析证据，
  且链路断开时 p5 会停在 hiboot 解不出的图上。
- 55fe8b2：已回退到 134943Z 已知可显示形态，判据回到三件套
  （logo / 绿带 / IP）。

用户据此判断当前路线过于脆弱、依赖太多不可控的交接条件，决定**提前启动
postmarketOS 式移植**作为主线，而不是继续在 hiboot 残留状态上打补丁。

注意：全黑是 **hiboot 阶段、内核启动之前**的问题，本身并不是「内核起来后没有
显示驱动」。启动 plan B 是**路线级决策**，不是因为判据落在了 B 分支。

## 1. 当前判据与已知事实

`main` 的三件套判据（`docs/024` §6）仍然有效，但**阶段 logo 判据已废弃**
（153551Z 回退后不再打包 stage 图）：

| 信号 | 来源 | 含义 |
| --- | --- | --- |
| `Debian Linux` logo | hiboot | 刷机链执行到最后一步 |
| 绿带 | 内核驱动 | 内核启动到 `hi3798-hdmi-console` 的 initcall |
| 路由器新 IP | 网络 | 内核 + rootfs + DHCP 起来了 |

已确证的三个"不是"（`docs/024` §6.3）：FB/fbcon/VT 全 `=y`；
`simplefb.c` 支持 platdata 路径；`a8r8g8b8` 格式合法。
两个真实疑点：fbcon 绑定层、以及**显存未用 `no-map` 保留**导致的
`ioremap_wc` 与内核线性映射属性冲突（`docs/028` §5.1 有外部资料逐字印证）。

## 2. 方法论（postmarketOS 式，不照抄具体设备）

完整调研见 **`docs/028`**（工作流、反馈通道、寄存器提取手法、上游现状）。
核心：

- vendor(downstream) 内核当**只读参考**，提取硬件行为，用 mainline 的
  DRM/KMS、clock、reset、regulator、CMA、DT binding **重新实现**，不是搬驱动。
- **第一优先级是反馈闭环**，不是显示。pmOS 排序 UART > simplefb > ramoops
  （ramoops 官方称 last resort）。本机**无串口硬件**，等于被推到最难一档，
  所以「把状态画到屏幕上」的阶段图/绿带本质是在补造 UART 替代品，方向正确。
- **连续 splash**：hiboot logo → simplefb → DRM fbdev 全程不黑屏。
- **`no-map` 是硬约束**：`simplefb` 的 `reserved-memory` 节点必须带 `no-map`，
  否则 ioremap 冲突甚至 panic（`docs/028` §5.1）。
- **显示时钟必须保留 bootloader 状态**：`clk_ignore_unused` / 禁用 dispcc，
  否则内核初始化时钟会重置 bootloader 设好的状态导致画面死（`docs/028` §5.2）。
- **最小 DTS 起步**：「The less you add, the easier it is to debug what broke」。
- 与 pmOS 差异：无串口、无 `lk2nd`、DTB append 到 uImage（不是单独存放）、
  目标是 HDMI 输出而非手机 panel、Debian armhf + CI 出 sparse 刷机包。

## 3. 可用资产

| 资产 | 位置 / 状态 | 用途 |
| --- | --- | --- |
| 原厂 Android 整机备份（4.5G 分卷 zip，16 分区） | 项目内 `TMP/stock-partition-backups/`（gitignored） | 一手规格：hiboot 二进制、生产内核、寄存器常量、HAL、参数表 |
| **原厂显示栈静态逆向成果** | **`docs/027`**（590 行，入库） | 显示驱动全内建、无可复用 `.ko`；`0xf8cc0000`/`0xf8ce0000` 实证；HAL 面；关键输入清单与仍缺 9 项 |
| HiSTB SDK（`HiSTBLinuxV100R005C00SPC060`） | `docs/021` / `docs/022` | `HDMI_Display()` 序列、VO 寄存器偏移、PHY 参数 |
| 原厂 recovery 逆向 | `docs/023` | `LOGO_TABLE`、`/dev/graphics/fb0`、初始化链路 |
| 社区 Ubuntu 在线调试平台 | SSH（凭据只在会话中） | 实测 `smem_start` / stride / 1920x1080 / `a8r8g8b8` |
| histb-mainline 补丁集 | `docs/025`；原文 `TMP/histb-ref/`（4 份，未入库） | mv100 DRM/HDMI 参考实现、EC6108V9C 板级 DTS |
| **histb-mainline 7.3 主线树** | 上游组织（见 `docs/028` §6） | **2026-10 已在同一块 EC6108V9C 上点亮 mv100 HDMI**，最有价值的现成基线 |
| 本地 QEMU 验证 | `scripts/qemu-local-test.sh` | 换内核 / 改 DTS 前跑 rootfs 启动基线 |
| 现有 6.3 资产 | `docs/024`/`docs/026`、`configs/partition-layout.env`、pstore、绿带标记 | 判据与验证闭环直接复用 |

**发送器形态已厘清**（`docs/029`，§5 第 1 步已完成）：拉取 histb 补丁原文后确认
**mv100（含 EC6108V9C）走 SiI9134 发射器 / bridge 链路**——
`500-02` 新建 `sii9134.c` + `hi3798mv100-hdmi.c`，DT 节点 `hdmi@8ce0000`
（`hisilicon,hi3798mv100-hdmi`）；`0xf8ce0000` 属 hi3716cv200，不是本板；
`600-17` 的片内 TX 是 mv200 的。
→ `docs/025` §8 "mv100 走 sii9134" 方向正确（仅"外挂"措辞不精确），
`docs/027` §6 曾据 `0xf8ce0000` 误判并"推翻"它，现已撤销（两处均已加更正）。
plan B 取 bridge 链路，不取 `600-17`。

## 4. 内核基线：已定为 B（HISTB 上游）

**决策（2026-11-08）**：采用 **基线 B = HISTB 上游**——Linux `7.4-rc1`
（`BASE_SHA 6628e7d4c6b2`）+ `histb-mainline/patches` 的 177 个 quilt 补丁。
流水线见 `docs/030`。下面的原候选分析保留作决策依据。

调研（`docs/028` §6）带来的新事实改变了原 §4 的成本排序：

- **A. 留在 6.3-rc5**：把 vendor 显示序列重写成 6.3 能接受的形态。
  优点：完整保留 DTS / cmdline / 8 分区刷机链 / 判据，成本最低。
  缺点：`DRM_CLIENT_SELECTION`、`DRM_BRIDGE_CONNECTOR` 缺失，
  `drivers/gpu/drm/histb/` 与相关 bridge 都没有；不是 upstream 方向。
- **B. 切 histb-mainline 7.3 主线树**：上游已在**同一块 EC6108V9C** 上点亮
  mv100 HDMI（2026-10），并有活跃的 patches 仓库与 LKML 补丁。
  优点：方向正确、有已验证成果，比自己从零重写划算得多；`docs/029` 确认的
  bridge 链路补丁本就来自这套树。缺点：需迁移 DTS / cmdline / 分区布局，
  重新打通刷机链；该树不再默认提供预编译内核。
- C. mainline 7.4 + 全量 quilt series：154 个补丁互相依赖，成本最高，
  且用户此前明确要求暂缓维护，暂不优先。

**已定 B**：`docs/029` 厘清了发送器形态，显示链是「DRM VDP2 + sii9134 bridge
+ CRG + 板级 DTS」一整套互相依赖的补丁（pending-7.4 显示子集约 20+ 个），
逐个反向移植到 6.3 的成本远高于直接采用已在同一块 EC6108V9C 点亮 HDMI 的
7.3/7.4 上游树（`docs/025` §8 + `docs/028` §6）。源码接入方式见 `docs/030`：
不建内核子模块，CI 按 `BASE_SHA` 拉一次性内核树 + quilt 全量 series。
`docs/030` §4 列了首次 CI 可能失败的点，按日志迭代，不盲目整套替换。

## 5. 分阶段计划（启动后执行顺序）

1. **【已完成 2026-11-08】厘清发送器形态与补丁基线**：拉取 `500-01`/`500-02`/
   `600-19`/`600-20`/`910-01`/`910-06` 补丁原文（项目内 `TMP/porting-patches/`），
   结合既有 `TMP/histb-ref/`，确认 mv100 走 SiI9134 bridge 链路、`0xf8ce0000`
   属 hi3716cv200、`600-17` 片内 TX 属 mv200，撤销 `docs/027` §6 的误判。
   产出：**`docs/029`**（含补丁基线清单与证据链）。
2. **【已完成 2026-11-08】搭好流水线**：基线定为 B（`docs/030` §1）；新建
   `.github/workflows/build-histb.yml`（独立触发/独立 tag/独立 concurrency，
   只监听本分支）、`scripts/build-kernel-histb.sh`、
   `configs/kernel/histb-ec6108v9c.config`。复用 `build-rootfs.sh` 与
   `make-community-flash-package.sh`，产出完整 U 盘刷机包。**首次 CI 结果待验证**，
   失败点清单见 `docs/030` §4，按日志迭代（裁剪 series / 修 config / 修依赖）。
   编译验证一律交 CI，本地不构建镜像。
3. **验证闭环**：QEMU 基线 + 绿带 + pstore，改任何驱动前先确认「改坏能看出来」。
   注：153551Z 的教训是 hiboot 命令链改动属高风险，最小实验要一次只改一处。
4. **提取序列**：反汇编 `p01_fastboot.img` 与 p11 的 `vmlinux`
   （`docs/027` §7.1 已列出二者为"最贴近实际刷入固件"的输入），
   与 SDK `HDMI_Display()` 逐字节核对，整理 VO layer0 / HDMI TX / PHY /
   clock / reset / EDID 时序。
5. **最小驱动**：只复现 hiboot 画面，不接 fbcon / DRM，用绿带同款机制确认
   寄存器写对。
6. **接控制台**：simplefb 或最小 DRM/KMS，让内核日志上屏。
7. **去私有依赖**：DT 清理、clock/reset provider、CMA，去掉 MMZ/MPP 依赖。
8. **评估 upstream**：按 subsystem 拆补丁，评估往主线靠拢的成本。

## 6. 与 main 的关系

- `main` 继续刷机迭代与 CI release；本分支**不覆盖** `main` 的 U 盘刷机包。
- 本分支通过 merge 同步 `main` 的文档与改动，但**不回写** `main` 的刷机链 /
  内核 config / workflow（除非某天产出要回合的最小补丁）。
- 若产出可用驱动，以**最小补丁**回合 `main`，不要整体合并分支。
- 不要把本分支的产物当作可刷 release 发给设备。
- 本分支的 push **不触发 release workflow**（`push.branches` 只有 `main`）；
  将来要在分支上编译内核，用 `gh workflow run build-release.yml --ref mainline-porting`
  手动触发，或先在 `main` 验证。

## 7. 硬件与协作约束（沿用既有结论）

- **没有串口硬件**：一切硬件调试走 SSH / 在线系统 / 寄存器，禁止依赖串口日志。
- **不要不安全地探测寄存器**：曾因 `/dev/mem` 扫 VO/HDMI 控制寄存器导致在线
  系统 external abort、画面消失。探测前先确认页已映射，且优先只读。
- **不在本地构建 rootfs / 系统镜像**：打包、生成 ext4/sparse 一律交给
  GitHub Actions；本地只做毫秒级校验（`bash -n`、CRC、env 解析、zip 清单）。
- **推送内容不得含本机绝对路径**或可识别本机用户名 / 隐私的信息；用相对路径
  或通用占位描述本地资源。
- **提交前显式 `git add <具体路径>`**，不用 `git add -A`；提交后
  `git show --stat --oneline HEAD` 核对 staged 内容。
- 临时产物放仓库内 `TMP/`（已被 `.gitignore` 排除），不要放到仓库外目录。
- 团队研究成果必须落在**入库文档**（本次 `docs/027` 已落实），不能只留在 TMP。

## 8. 文档索引（本分支已全部带入）

| 文档 | 内容 |
| --- | --- |
| `docs/020`/`021` | simplefb 路线死结 → 改走驱动移植的决策 |
| `docs/022`/`023` | SDK 寄存器与初始化序列 → 原厂 recovery 逆向 |
| `docs/024` | 启动/显示链路审查、A/B/C 判据、绿带标记、**§6.5 全黑回归复盘** |
| `docs/025` | pmOS 方法论、histb-mainline 成果、**§8 反向移植评估（含一条已被 027 推翻的结论）** |
| `docs/026` | 网络 / DHCP 侧审计 |
| **`docs/027`** | **原厂 Android 显示栈静态逆向（团队成果）；§6 结论已由 029 撤销，见该节顶部更正** |
| **`docs/028`** | **postmarketOS 主线化工作流调研（含 no-map / clk 外部印证）** |
| **`docs/029`** | **发送器形态厘清（plan B 第 1 步产出，含补丁基线清单）** |
| **`docs/030`** | **HISTB 上游构建流水线（plan B 第 2 步产出，独立 workflow / 已知风险 / 迭代清单）** |

> 流水线三件套：`.github/workflows/build-histb.yml`、
> `scripts/build-kernel-histb.sh`、`configs/kernel/histb-ec6108v9c.config`。
> 补丁原文（gitignored 不入库）：`TMP/histb-ref/`（既有 4 份）、
> `TMP/porting-patches/`（本次新增 6 份）、`TMP/histb-pending.json` /
> `TMP/histb-hack.json`（154+23 项清单）。
