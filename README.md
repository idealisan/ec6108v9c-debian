# ec6108v9c-debian

给华为悦盒 EC6108V9C（HiSilicon Hi3798MV100，4×Cortex-A7，1GB DDR3，eMMC）刷 Debian armhf 的构建仓库。

仓库只做两件事：

1. **逆向记录**：`docs/` 下的分析报告，说明该平台的引导链、分区表、刷机机制与驱动移植进展；
2. **自动化构建**：GitHub Actions 用 **Linux 7.4-rc2 + histb quilt 补丁系列**构建内核、用 debootstrap 构建 Debian rootfs，组装成 U 盘刷机包并发布 Release。

## 当前状态（2026-11-19）

- 分支 `histb-7.4`：内核基线 **Linux v7.4-rc2**（`7475ea8b`），`patches/histb/` 中 117 个上游补丁 + 板级 `820-01` boot DTS overlay，本地 `quilt push -a` 已干净应用。
- 最新发布：`build-20261118T153207Z`（`· debian12-armhf + histb-7.4 + recovery-flasher USB`）。历史版本见 GitHub Releases。
- 真机：7.4 内核的显示栈（VDP KMS + SiI9134 bridge + lima）已编译，**但尚无 7.4 真机 probe 日志**；7.4 首次 bring-up 与后续驱动移植计划见 `docs/056-7.4-driver-bringup-plan.md`。
- 已知限制：GPU 渲染模式下曾出现硬锁死；X11 仍可能回退 llvmpipe；SSH `reboot` 后 eMMC 未重枚举（冷启动正常）。详见"风险"章节。

## 目录结构

    .github/workflows/build-release.yml   CI：构建 + 发布 release（仅 workflow_dispatch）
    configs/kernel-baseline.env           内核基线版本 / commit / defconfig（单一事实源）
    configs/partition-layout.env          分区与内存布局（DTB cmdline 与 p2 runtime env 共用）
    configs/kernel/ec6108v9c.config       内核 config fragment
    patches/histb/                        7.4 quilt 补丁库（117 补丁 + 820-01 板级 overlay，事实源）
    patches/kernel/                       6.3 历史 backport 补丁（保留参考，当前流水线不用）
    patches/vendor-display/               6.3 私有显示驱动实验（保留参考，当前流水线不用）
    scripts/build-kernel.sh               CI 使用：7.4-rc2 + quilt 构建 uImage 与模块
    scripts/build-rootfs.sh               CI 使用：debootstrap 构建 Debian armhf rootfs
    scripts/make-community-flash-package.sh   CI 使用：社区格式 U 盘包（legacy fallback）
    scripts/make-recovery-flash-package.sh    CI 使用：recovery-flasher 包（推荐，真机已验证方法）
    scripts/qemu-local-test.sh            CI 使用：QEMU 启动 rootfs 并验证 SSH
    scripts/fix-cma-bootargs.py           本地修复 p2 runtime env 中 cma= 参数
    scripts/mkbootargs.py / img2simg.py   bootargs.bin（含 CRC32 头）/ ext4 → sparse
    scripts/make-references-archive.sh    第三方资料快照归档（默认关闭）
    scripts/fetch-sdk.sh / build-sdk-components.sh  旧 SDK 路线（hiboot + 4.4 内核），CI 不用
    scripts/make-extra-packages.sh / make-emmc-package.sh / make-live-usb.sh / make-rescue-p11.sh
                                          历史/诊断用途脚本，CI 不用，勿据此判断当前能力
    third_party/linux-hi3798mv100         内核源码子模块（当前流水线按 SHA 直接 fetch rc2）
    firmware/                             内置 WiFi 固件（rtl8188fufw.bin）
    recovery-flasher/                     刷机用的 stock recovery / flasher 源码
    references/                           本地归档的工具与说明（USBFormat.exe 等）
    docs/                                 逆向分析与进展文档（索引：docs/INDEX.md）
    dist/ / build/ / TMP/                 产物与本地中间文件（TMP/ 已 gitignore）

## 内核源码

`third_party/linux-hi3798mv100` 的 `.gitmodules` URL 是
[`histb-mainline/linux`](https://github.com/histb-mainline/linux)，基线为 **v7.4-rc2**，
dereferenced commit `7475ea8b58616b33c04afb976cf0fbaad9dd63fb`（见 `configs/kernel-baseline.env`）。

子模块的 fork 分支 tip 可能是 7.4-rc4，因此 **CI 不依赖 `git submodule update --depth 1` 的 tip**，
而是 `git fetch --depth 1 origin $BASE_COMMIT` 后 `--detach` 到指定 commit；
`scripts/build-kernel.sh` 也会断言 HEAD 与 `BASE_COMMIT` 一致，否则自行 fetch。
补丁以 `patches/histb/` 的 quilt 系列为准（编号/分组/提交头规则见 `patches/histb/README.md`）。

本地提示：macOS 默认的大小写不敏感文件系统下，内核树中 `xt_DSCP.c`/`xt_dscp.c` 这类
**仅大小写不同**的文件会互相覆盖，导致 `git status` 误报修改。本地已把 13 个这类路径标记为
`skip-worktree`（可用 `git update-index --no-skip-worktree` 按路径恢复），旧的 netfilter 实验改动
保存在子模块 `stash@{0}`，另有一份 diff 备份在项目内 `TMP/submodule-netfilter-pre74.diff`（未入库）。
CI 每次 fetch 干净基线，不受这些本地状态影响。

## 构建与发布

- 触发：`workflow_dispatch`，**push 不触发**（旧 push 构建走无用的 simplefb 路径，浪费 CI 时间并占并发槽）。
  例：`gh workflow run build-release.yml --ref histb-7.4 -f display_driver=vendor-backport`
- 常用输入：
  - `display_driver`：`vendor-backport`（实际刷真机的方案，默认）/ `simplefb`（遗留参考）
  - `extra_cmdline`：追加内核参数（如 `cma=160M`；会同时进 DTB 和 p2 runtime env，**不只是 DTB**）
  - `archive_refs`：是否归档约 2GB 的第三方快照，默认 `false`
  - `fb_*`：仅 simplefb 路径使用的 framebuffer 参数
- 并行 job：`build-kernel`（quilt + defconfig + 硬断言）与 `build-rootfs`（debootstrap，desktop/server 两个变体）
  各自产出 artifact；`package` 汇总后生成四个刷机包（桌面/服务器 × recovery/community）；
  `qemu-boot-test` 对两个变体分别验证能启动且 SSH 可达。
- 制品以 CI release 为准；本地只做只读分析和轻量校验（不本地出包、不直接写真机）。

## 产物

| 文件 | 说明 |
|---|---|
| `mv100-mdmo1g-mainline-recovery-flash-desktop-*.zip` | **推荐（桌面版）**：recovery-flasher 包 + XFCE 桌面 rootfs；已真机验证 1920x1080/4K30 |
| `mv100-mdmo1g-mainline-recovery-flash-server-*.zip` | **推荐（服务器版）**：同一刷机程序 + **无桌面** rootfs（只有 SSH/telnet/WiFi/CLI），适合长期当 server 用 |
| `mv100-mdmo1g-debian-usb-flash-{desktop,server}-*.zip` | 社区格式 legacy fallback（hiboot mmc-write 脚本），两个变体各一个 |
| `hi_kernel.bin` | uImage = zImage + DTB，加载 `0x2000000`，写入 p6（LBA `0x7000`） |
| `modules.tar.gz` | 内核模块 `/lib/modules` |
| `debian-rootfs-armhf-bookworm-{desktop,server}.tar.gz` | 两种变体的纯 rootfs tarball（参考用，不直接刷） |
| `patches/kernel/*` / `SHA256SUMS.txt` | 构建时使用的补丁与校验和 |
| `references-*.tar.gz` / `snapshot-*.tar.gz` | 可选资料快照，仅在 `archive_refs=true` 时生成 |

每次发布同时产出 **desktop** 和 **server** 两个变体，刷机流程相同，只是 rootfs 不同：

- **desktop**：XFCE + Mesa lima/kmsro + GPU 服务；可进桌面，默认软件渲染，
  4K30 已真机验证；GPU 模式在浏览器负载下会 lima job timeout，不建议日常使用。
- **server**：不装 X/Mesa/XFCE，不启用 GPU/桌面服务；开机进 TTY，SSH/telnet 可用，
  适合长期当服务器。内核与刷机包其余部分与 desktop 版一致。

## 刷机方式

1. U 盘格式化为 FAT32/MBR，把**推荐包**解压到根目录；保留社区 `fastboot.bin`（BootROM 在短接上电时加载它，此包永不写 p1）。
2. 盒子断电，插 U 盘，按住恢复键上电；hiboot 读取根目录 `bootargs.bin` → `fatload recovery.img; bootm`。
3. recovery 内核点亮 HDMI 并运行终端 flasher：滚动的 `<数字> <TEXT>` 日志，按绝对 LBA 写 p2/p5/p6/p8，停在 `6 DONE NO REBOOT`。
4. 断电拔 U 盘，正常上电进入 p8 上的 Debian：串口 `ttyAMA0 115200`，SSH `root@<ip>` 密码 `ec6108v9c`（**首次登录后立刻修改**），telnet 23 也开着。首次启动自动 `resize2fs` 扩容。
5. WiFi：`ec6108-wifi <SSID> <password>`；温度：`ec6108-temp`。

分区布局（内核 `blkdevparts` 定义，盘上无分区表，见 `configs/partition-layout.env`）：

    p1 boot     1M   @0
    p2 bootargs 1M   @1M
    p3 baseparam 4M  @2M
    p4 pqparam  4M   @6M
    p5 logo     4M   @10M
    p6 kernel   20M  @14M
    p7 busybox  64M  @34M
    p8 debian   剩余  @98M     ← root=/dev/mmcblk0p8

## 驱动现状与计划

7.4 的补丁系列已经把 eMMC/SD、以太网、USB、WiFi、IR、DRM/KMS 显示、GPU、视频编解码、音频、
thermal、watchdog 等驱动源码与 DT 节点带进内核；当前工作重心是**逐项验证并启用**它们，
而不是重写驱动。完整设备矩阵、阶段计划（P0 真机 bring-up → P1 显示收敛 → P2 补 config 缺口
→ P3 稳定性 → P4 深度功能）与验收标准见 **`docs/056-7.4-driver-bringup-plan.md`**。

## 文档

全部文档的索引与编号状态见 `docs/INDEX.md`。常用入口：
`docs/001-boot-and-flash-analysis.md`（引导/刷机）、`docs/050-recovery-userland-flasher.md`（推荐刷机机制）、
`docs/053-real-hw-verify-sop.md`（真机判据）、`docs/054-first-userspace-probe-report.md`（6.3 根因）、
`docs/055-histb-drm-backport-plan.md`（显示/GPU 路线）、`docs/056-7.4-driver-bringup-plan.md`（当前计划）。

## 风险

- 刷机有变砖风险，务必先做整机备份；回滚方案见 `docs/006-restore-to-stock.md`。
- **p1 永不写**：该刷机方式依赖盒子原有的 hiboot；若 p1 被破坏，需要 HiTool/串口救砖。
- 显示是"尽力而为"：7.4 的 drm-histb KMS 尚未有真机验证报告；GPU 渲染模式下曾硬锁死、X11 曾回退 llvmpipe。
- `cma=160M` 必须进 p2 runtime env；16MiB 时曾触发硬锁，不能只写进 DTB。
- warm reboot 在 6.3 上失败（eMMC 未重枚举），7.4 需专门复验；当前建议断电重启。

## 工作方式

- 制品只认 CI release；本地只做 `bash -n`、`git apply --check`、`quilt push`、`dtc` 等轻量校验。
- 改驱动改 `patches/histb/`（quilt 是事实源），同步 config fragment 与 build 断言，同一 commit 提交。
- commit message 不带任何 AI/trailer/署名追加信息；提交前显式 `git add <具体路径>`。
- `TMP/` 是本地中间产物（已 gitignore）；不访问项目外临时目录，不做未确认的删除/清理。
