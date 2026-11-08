# 030 — HISTB 上游构建流水线（plan B 第 2 步产出）

> 状态：**已搭建，待 CI 首次验证**（2026-11-08）。
> 目标：在 `mainline-porting` 分支上打通「HISTB 上游内核 → 编译 → U 盘刷机包」
> 的整条流水线，让该分支 push 即构建、自带 release，**不再需要合并到 main**。
> 本文是链路/流水线的说明与已知风险清单，不是显示驱动实现。

---

## 0. 为什么独立 workflow

`main` 的 `build-release.yml` 是 loonpn 6.3-rc5 + 3 个本地补丁的老流程，仍在按
需出 6.3 的刷机包。plan B 换的是完全不同的内核来源，塞进同一个 workflow 会
让 main 的构建跟着变，风险不可控。因此新建独立
`.github/workflows/build-histb.yml`：

| | `build-release.yml`（main） | `build-histb.yml`（mainline-porting） |
| --- | --- | --- |
| 触发分支 | `main` | `mainline-porting` |
| 内核 | loonpn 6.3-rc5 子模块 + 3 补丁 | Linux 7.4-rc1 + histb quilt 177 补丁 |
| 构建脚本 | `build-kernel.sh` | `build-kernel-histb.sh` |
| release tag | `build-$STAMP` | `histb-$STAMP` |
| artifact 名 | `kernel-dist` / `rootfs-dist` | `histb-kernel-dist` / `histb-rootfs-dist` |
| concurrency group | `build-release-<ref>` | `build-histb-<ref>` |

两条流水线**互不取消、互不覆盖**。rootfs 与刷机包脚本
（`build-rootfs.sh` / `make-community-flash-package.sh`）与内核版本无关，直接复用。

## 1. HISTB 上游的真实形态（已核实）

不是一棵现成内核树，而是「一次性内核树 + 补丁集是真相」：

- `baseline`：`KERNEL_VERSION := 7.4-rc1`，`BASE_SHA := 6628e7d4c6b2`
  （= torvalds/linux 的 `Linux 7.4-rc1` tag commit，已核实可访问）。
- `histb-mainline/patches` 的 `series` 共 **177 行**：154 `pending-7.4` +
  23 `hack-7.4`（`backport-7.4` 为空桶）。`quilt.conf` 规定 `--fuzz=0`、
  `QUILT_PATCHES` 指向补丁集目录、`QUILT_PC=.pc`。
- 用户 fork `idealisan/hisilicon-linux-mainline`（fork 自 patches 仓库）内容
  与上游一致（177 行 series、154+23 文件），作为可维护的补丁源；
  `histb-mainline/linux`（fork 自 torvalds/linux）默认分支 `histb` 已被清空，
  只剩 README，**不作为源码来源**。
- 上游 README 明确：「Kernel trees are disposable and are extracted from the
  baseline commit；patch files and series 才是 source of truth」。

## 2. 源码接入方式（不建内核子模块）

`scripts/build-kernel-histb.sh`：

1. clone 补丁集（`PATCHES_REPO`，默认用户 fork，`PATCHES_REF` 默认 master）。
2. 从 `baseline` 读 `BASE_SHA`（可用 `KERNEL_BASE_SHA` 覆盖做可复现钉住）。
3. 用 GitHub codeload tarball 拉该 SHA 的一次性内核树：
   `codeload.github.com/torvalds/linux/tar.gz/<SHA>`（短 SHA 已验证可用，
   ~1.9 GB 解压），`--strip-components=1` 解到 `build/histb/linux`。
   → 不需要 6 GB 的 fork clone，也不建内核子模块。
4. `QUILTRC=<patches>/quilt.conf quilt push -a`（在内核树内），全量 177 补丁，
   失败即停（--fuzz=0 漂移要修补丁集，不能糊）。
5. `multi_v7_defconfig`（补丁集没有 defconfig）+ `configs/kernel/histb-ec6108v9c.config`
   片段 → `olddefconfig` → 编译 `zImage dtbs modules`。
6. `cat zImage hi3798mv100-ec6108v9c.dtb > zImage-dtb` → `mkimage` 成
   `dist/hi_kernel.bin`（load 0x2000000），`modules_install` → `dist/modules.tar.gz`。

DTB 路径是 `arch/arm/boot/dts/hisilicon/` 子目录（7.4 布局），
`910-06` 补丁把 `hi3798mv100-ec6108v9c.dtb` 加进该目录 Makefile。

## 3. 关键配置依据（`configs/kernel/histb-ec6108v9c.config`）

| 选项 | 依据 |
| --- | --- |
| `CONFIG_ARM_APPENDED_DTB=y` | 7.4-rc1 的 `arch/arm/Kconfig` 仍有该项；hiboot 用 `bootm` 启动 zImage+DTB 拼接的 uImage，必需 |
| `CONFIG_ARM_ATAG_DTB_COMPAT=y` | hiboot 通过 ATAG 传 cmdline；不往 DTB 注入 bootargs，沿用社区启动方式 |
| `CONFIG_ARCH_HISI=y` | 板级 SoC |
| `CONFIG_DRM_HISTB_VDP2=y` | `600-17` Kconfig，`depends on DRM && OF && ARM`（32 位 VDP2）；VDP4/HDMI 是 ARM64，不选 |
| `CONFIG_DRM_SII9134=y` | `500-02` Kconfig（`drivers/gpu/drm/bridge/Kconfig`），mv100 发射器，见 `docs/029` |
| `CONFIG_COMMON_CLK_HI3798` / `RESET_HISI` | HDMI ctrl/phy 时钟与复位 provider |
| `CONFIG_HISI_FEMAC` / `EXT4_FS` / `PSTORE_RAM` | 网络、rootfs、无串口下唯一日志通道 |

片段里对 7.4 不存在的符号会被 `olddefconfig` 丢弃而不报错；CI 的
「verify key options」步骤打印实际落地值，按**证据**迭代，不靠猜。

## 4. 已知风险 / 首次 CI 可能失败的点（诚实清单）

这是「先打通链路」的第一版，**不承诺显示可用**，只承诺流水线可复现地产出
刷机包。首次 `push` 可能在这些地方失败，需按日志迭代：

1. **quilt push -a**：`--fuzz=0` 严格；若补丁集相对 `BASE_SHA` 漂移，会在某个
   补丁处停。对策：核对该补丁与 baseline，或在 fork 上 reconcile。
2. **补丁含 `hack-7.4/990-*` bench 专用项**（如 990-13 register snapshot、
   990-23 bench harness）：这些是上游调试补丁，可能引入编译期依赖或
   `EXPERT`/staging 配置要求。必要时把 series 裁到显示子集（patch 集是真相，
   裁剪等于改我们自己的 series 副本）。
3. **DRM 依赖链**：`DRM_HISTB_VDP2` select `DRM_CLIENT_SELECTION` /
   `DRM_BRIDGE_CONNECTOR` 等 7.x 新符号；若 7.4-rc1 缺某个 helper，编译报错。
4. **cmdline / 分区**：`make-community-flash-package.sh` 写 p2 env 用的是
   `configs/partition-layout.env` 的 8 分区 `blkdevparts`（为 6.3 定的）。
   7.4 的 `blkdevparts` 解析、`root=mmcblk0p8`、内存/时钟参数是否仍适用，
   需真机验证；第一版先保证能出包，不做启动承诺。
5. **刷机包脚本的检查**：`make-community-flash-package.sh` 有
   `K_SECTORS > 40960`（p6 20 MiB 上限）等假设；7.4 的 zImage+DTB 若变大需复核。
6. **显示驱动与 hiboot 的关系**：`docs/028` §5.1/§5.2 的 `no-map` 与
   `clk_ignore_unused`（或禁用 dispcc）约束对 DRM 路径同样成立，属后续阶段。

## 5. 如何触发 / 取产物

- push 到 `mainline-porting` 分支（改动 `scripts/**`、`configs/**`、
  `.github/workflows/build-histb.yml`）自动触发。
- 或手动：`gh workflow run build-histb.yml --ref mainline-porting`
  （可传 `patches_repo` / `patches_ref` / `kernel_base_sha` / `skip_modules`）。
- 三个 job：`build-kernel-histb`（内核）、`build-rootfs`（Debian rootfs）、
  `package`（并行产物 → 刷机 zip + `histb-$STAMP` release）。
- 产物：`mv100-mdmo1g-debian-usb-flash-<STAMP>.zip` = 可放进 U 盘的刷机包，
  另有 `hi_kernel.bin`、`modules.tar.gz`、rootfs tarball、`SHA256SUMS.txt`。

## 6. 与 plan B 路线文档的关系

- `MAINLINE-PORTING.md` §4 基线决策 → 本文落实**基线 B（HISTB 7.4）**。
- `MAINLINE-PORTING.md` §5 第 2 步（定基线 + 搭源码接入 + 整理 series）→
  本文完成其中的**流水线骨架**（源码接入 + 全量 series + CI 编译链路）；
  「裁剪 series 到显示子集 / 逐补丁编译验证」留到首次 CI 日志之后。
- `docs/029` 确定发送器形态（SiI9134 bridge 链路），本文据此开 DRM 配置。
- `docs/028` 是方法论，`docs/027` 是原厂一手证据，两者是后续驱动阶段输入。
