# mainline-porting 分支：postmarketOS 式移植工作区

> 这是 **plan B 的独立工作区**，从 `main`（6.3-rc5 + 现有刷机链 / 显示判据）
> 分出。当前只有这份路线说明，**没有改代码、没有改 CI、没有换内核**。
> `main` 继续进行刷机迭代，两边互不阻塞。

## 0. 为什么留这条后路

当前 HDMI 路线是「**借** hiboot 留下的 framebuffer」：

1. hiboot 初始化 VO / VDP / HDMI TX / PHY 并画出 p5 logo；
2. `hi3798mv100-hdmi-console.c` 从 VO `G0_ADDR` 读出显存地址；
3. 注册 `simple-framebuffer`，让 fbcon 在这块显存上打日志。

这是**交接**，不是驱动。它完全依赖 bootloader 残留状态：任何 clock gating、
显存被内核占用、simplefb/fbcon 绑定失败，都会让屏幕停在 logo。
如果这条路反复不通，就需要按 postmarketOS 的做法——**从原厂安卓的显示驱动
逆向出初始化序列，重写成符合 mainline 子系统规范的驱动**。

## 1. 触发条件（什么时候才真正启动）

刷 `main` 的下一版后，按 `docs/024` §6 + `docs/026` §4 的判据读屏幕：

| 现象 | 归类 | 是否启动本分支 |
| --- | --- | --- |
| 停在 `0-4`..`3-4` 阶段 logo | 刷机链断在某一步 | 否，先按阶段图定位写入 |
| `Debian Linux` + 无绿带 | A：内核没跑到 initcall | 否，先查 p6 / DTB / `mem=` |
| 绿带出现 + 有内核文字 | 全链路通 | 否 |
| 绿带出现 + 无文字 / 无 IP | B/C：显示或网络 | 先在 `main` 试 simplefb 最小修复（`fb_base` → `no-map` 保留显存） |
| **上述最小修复仍不通** | 当前路线不可靠 | **是，启动本分支** |

关键：**不要因为「看不到日志」就直接跳到重写驱动**。阶段 logo 与绿带已经把
「刷机没写完 / 内核没起来 / 显示没接管」分开了，先在 `main` 上把便宜的修复
试完。

## 2. 方法论（postmarketOS 式，不照抄具体设备）

- 把 **downstream vendor kernel**（原厂安卓 3.x/4.4 内核 + 私有 MPP/HIFB 栈）
  与 **mainline kernel** 当成两条独立的线；目标不是把私有驱动搬过来，而是
  **提取它做了什么**，再用 mainline 的 DRM/KMS、clock、reset、CMA 框架重写。
- **连续 splash**：hiboot logo → simple-framebuffer → DRM fbdev，全程不黑屏，
  这正好复用我们已有的阶段 logo 与绿带机制。
- **日志通道**：本机**没有串口硬件**，唯一可靠的是 ramoops/pstore（已在
  `main` 上通过 `ramoops.dtsi` 激活）+ 在线系统 SSH。任何依赖串口日志的方案
  直接排除。
- **DT 清理**：`reserved-memory` / media CMA / clock & reset provider 是显示
  驱动能不能 probe 的前提（`docs/025` §8 已列出 6.3 上缺失的节点）。
- **逐个 upstream 化**：bridge / PHY / panel 分开写，先复现画面再谈 KMS。
- 与 pmOS 的差别：pmOS 常有串口和 `lk2nd` 之类的二级引导，我们只有
  U 盘 hiboot 刷机 + 在线 SSH，所以验证闭环必须更依赖「屏幕可见标记」。

## 3. 可用资产（均为通用描述，不含本机路径）

| 资产 | 位置 / 状态 | 用途 |
| --- | --- | --- |
| 原厂 Android 完整备份（p1–p16、boot0/boot1，约 7.3 GB） | 本地外置盘，未入库 | 提取原厂 boot/recovery 内核、私有显示驱动、分区与寄存器初值 |
| 原厂 recovery 逆向成果 | `docs/023-recovery-display-analysis.md` | `LOGO_TABLE`、`/dev/graphics/fb0`、recovery 显示初始化链路与细节 |
| HiSTB SDK（`HiSTBLinuxV100R005C00SPC060`） | `docs/021` / `docs/022` | `source/msp`、`graphic`/`hdmi`、VO 寄存器偏移、`HDMI_Display()` 序列 |
| 社区 Ubuntu 在线调试平台 | 通过 SSH（凭据只在会话中，不入库） | 曾实测 `smem_start` / stride / 1920x1080 / `a8r8g8b8`；可作寄存器/时钟对照 |
| histb-mainline 7.4 补丁集 | `docs/025`，补丁原文在 `TMP/histb-ref/`（未入库） | 现成的 mv100 DRM/HDMI 实现、EC6108V9C 板级 DTS，作为**参考实现** |
| 用户已 fork 的 histb patches 仓库 | 公开 GitHub 仓库（可选载体） | 若最终走 7.4，作为补丁维护点 |
| 本地 QEMU 验证 | `scripts/qemu-local-test.sh` | 换内核/改 DTS 前先跑 rootfs 启动基线 |
| 现有 6.3 资产 | `docs/024` / `docs/026`、`configs/partition-layout.env`、pstore、阶段 logo、绿带标记 | 判据与验证闭环直接复用，不必重造 |
| 另一个设备的 Debian 主线移植工程 | 本地私有仓库，未入库，仅借鉴策略 | pmOS 风格工程组织方式 |

## 4. 内核基线：两条候选（启动时再定，现在不决定）

- **A. 留在 6.3-rc5**，把 vendor 显示序列重写成 6.3 能接受的形态。
  优点：完整保留现有 DTS / cmdline / 8 分区刷机链 / 判据；
  缺点：`DRM_CLIENT_SELECTION`、`DRM_BRIDGE_CONNECTOR` 缺失，
  `drivers/gpu/drm/histb/` 与 sii9134 bridge 都没有（`docs/025` §8），
  而且不是 upstream 方向。
- **B. 切 mainline 7.4 + histb-mainline quilt series**。
  优点：上游已有 mv100 HDMI/DRM 成果，方向正确；
  缺点：迁移成本高，`pending-7.4` 有 154 个补丁互相依赖，
  且用户已明确要求暂缓维护、先出可刷产物。

**建议顺序**：先用 A 把「驱动逻辑能不能点亮屏幕」验证出来（成本低、判据现成），
再把验证过的寄存器序列 / DT 节点往 B 上搬。不要一上来就整套换内核。

## 5. 分阶段计划（占位，启动时细化）

1. **验证闭环**：QEMU 基线 + 阶段 logo + 绿带 + pstore 四件套，在改任何驱动前
   先确认「改坏了能看出来」。
2. **提取序列**：从原厂 recovery / SDK 整理完整显示初始化——VO layer0、
   HDMI TX / PHY（含 `600-18` 提到的 `VIDEO_PATH_CTRL` 与 PHY 0x09 按 die
   revision 配置）、clock / reset、EDID 时序来源。
3. **最小驱动**：只做「复现 hiboot 画面」，不接 fbcon、不接 DRM，用绿带同款
   机制确认寄存器写对了。
4. **接控制台**：simplefb 或最小 DRM/KMS，让内核日志出现在屏幕上。
5. **去私有依赖**：DT 清理、clock/reset provider、CMA，去掉对 MMZ/MPP 的依赖。
6. **评估 upstream**：按 subsystem 拆补丁，评估往 7.4 主线靠拢的成本。

## 6. 与 main 的关系

- `main` 继续刷机迭代与 CI release；本分支**不覆盖** `main` 的 U 盘刷机包。
- 本分支只增内容，不回写 `main` 的刷机链 / 内核 config / workflow。
- 若产出可用驱动，以**最小补丁**回合 `main`，不要整体合并分支。
- 不要把本分支的产物当作可刷 release 发给设备。

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

## 8. 文档索引

- `docs/020` simplefb 路线与其死结 → `docs/021` 改走驱动移植的决策
- `docs/022` SDK 提取的寄存器与初始化序列 → `docs/023` 原厂 recovery 逆向
- `docs/024` 启动/显示链路审查 + A/B/C 判据 + 绿带标记
- `docs/025` pmOS 方法论调研、histb-mainline 成果、**§8 反向移植到 6.3 的评估**
- `docs/026` 网络 / DHCP 侧审计
