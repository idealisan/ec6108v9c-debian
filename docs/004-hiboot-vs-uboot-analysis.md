# hiboot 与 U-Boot 差异分析 / 改用 U-Boot 的可行路径

- 分析日期：2026-11-02
- 对象：EC6108V9C（Hi3798MV100）p1 分区中的 `fastboot.bin`（"Fastboot 3.3.0_ecoo_81082668"）
- 方法：二进制静态分析（字符串/头部/命令表）+ 海思 SDK 源码比对 + 主线 U-Boot 现状调查
- 相关文档：`docs/001-boot-and-flash-analysis.md`（引导与刷机）、`docs/002-mainline-kernel-debian-survey.md`（内核）

## 1. 结论摘要

1. **hiboot 就是 U-Boot 的深度定制分支**，不是另起炉灶：二进制约 540 KB，但保留了 U-Boot 的 hush shell、
   `bootm` 子命令框架、`mii`/`usb`/`nand` 命令、`bootdelaykey`/`bootstopkey` 等原始字符串；
   SDK 里对应源码目录 `source/boot/fastboot/` 就是标准 U-Boot 树结构（arch/board/common/disk/drivers/fs/include/lib/net/tools）。
2. 基线版本：`Makefile` 中 `VERSION=3.3.0`（海思自编号，非上游版本号），版权头 2000-2010，
   特征串（`bootm_low`/`bootm_size`、hush、`mii dump`）指向 **U-Boot 2010 年前后** 的分支。
3. 改动集中在四块：**启动镜像格式（BootROM/DDR 训练/安全启动）**、**私有命令**（ddr/getinfo/mmc.ext4sp/升级）、
   **环境变量机制**（bootargs.bin 文件化 + 按内存大小变体）、**板级驱动**（himciv200 MMC、海思时钟/显示/PQ）。
4. **主线 U-Boot 没有 Hi3798MV100 支持**：`arch/arm/mach-histb` 只声明 `ARCH_HI3798MV2X`（ARM64/A53），
   而 MV100 是 ARM32/Cortex-A7。直接"换成主线 U-Boot"需要新写一个 ARM32 mach，工作量较大。
5. 可行的三条路线：
   - **A. 自编译 SDK 的 fastboot 源码**（= 拥有源码的"自己的 hiboot"）——成本最低、风险最小，可加命令（如 ext4load）
   - **B. hiboot 链式加载 U-Boot**（`fatload` + `go`）——保留 DDR/显示初始化，用现代 U-Boot 接管引导
   - **C. 直接把 U-Boot 烧进 p1 替代 hiboot**——需复刻 BootROM 头与 DDR 训练，风险最高，不建议

## 2. 二进制证据

### 2.1 镜像头部

```
0x00: 19 08 00 ea           b   +0x2064        ; ARM 复位向量
0x04: 14 f0 9f e5 x7        ldr pc, [pc, #-0x14] ; 异常向量跳转表
0x20: 40 4c c0 00 ...       0x00C04C40 ...      ; 指向 TEXT_BASE=0x00C00000 区域
0x3C: 0d 59 5a 43 "v1.1.0"  "YZC v1.1.0"        ; 海思私有标识（DDR 配置版本，对应串 "Reg Version: v1.1.0"）
```

- 裸镜像、无 U-Boot 的 U-Boot 头（无 `0x27051956` magic），由 BootROM 直接从 eMMC LBA 0 加载到 **0x00C00000** 执行
- 这也解释了内核加载地址 0x1FFFFC0 的来历：hiboot 自身占用 12 MB 起的一段 DDR，32 MB 以上才给内核

### 2.2 证明 U-Boot 同源的原始字符串

| 字符串 | 来源 |
|---|---|
| `print monitor version` | U-Boot `version` 命令 help |
| `HUSH_VERSION` | U-Boot hush shell |
| `bootdelaykey` / `bootstopkey` / `bootdelaykey2` / `bootstopkey2` | U-Boot 自动启动中断键 |
| `boot application image from memory` | U-Boot `bootm` help |
| `boot image via network using BOOTP/TFTP protocol` | U-Boot `bootp` help |
| `boot image via network using RARP/TFTP protocol` | U-Boot `rarpboot` help |
| `loados - load OS image` / `cmdline - OS specific ...` / `bdt - OS specific bd_t ...` / `prep - ...` | U-Boot bootm 子流程 |
| `mii device/info/read/write/dump` | U-Boot `mii` 命令 |
| `usb start/reset/stop/tree` | U-Boot `usb` 命令 |
| `** Invalid partition type "%.32s" (expect "U-Boot")` | U-Boot 引导代码 |

### 2.3 命令表实测（对比标准 U-Boot）

- **保留**：`bootm` `go` `run` `setenv` `printenv` `saveenv` `fatload` `fatls` `mmc` `usb` `mii` `i2c` `gpio`
  `nand` `tftp` `ping` `bootp` `rarpboot` `crc32` `cmp` `loop` `loadb` `reset`
- **没有**：`bootz` `booti` `fdt` `ext4load`/`ext2load`（源码有 fs/ext4 但命令未编译）`dhcp` `nfs` `ide` `scsi` `tftpboot`
- **新增**：见下节

> 注意：没有 `ext4load` 意味着 hiboot 不能从 ext4 根分区的 /boot 读内核，
> 内核必须放在 FAT 分区或裸分区（当前方案即裸分区 p6）。
> 没有 `fdt` 意味着无法在启动时改 DTB（只能靠 ATAG/DTB 内建或改内核配置）。

## 3. 相对 U-Boot 的具体改动

### 3.1 启动镜像与硬件初始化（最核心）

| 改动 | 说明 |
|---|---|
| BootROM 私有格式 | 镜像即裸 ARM 映像 + "YZC" 标识，由 SDK 工具链生成；U-Boot 原生镜像不被 BootROM 接受 |
| DDR 训练 | `cmd_ddr_training.c` + 板级 `.reg` 配置（`hi3798mdmo1g_hi3798mv100_ddr3_1gbyte_16bitx2_4layers_emmc.reg`），按板卡做写入均衡/眼图 |
| 安全启动 | OTP/TEE 一整套：`HI_UNF_OTP_GetBootMode/SetBootMode`、`EnableSCS`、`SetRSAKey`、`EnableTrustZone`、`set self_boot_disable` |
| 启动介质 | eMMC boot 分区选择（`mmc bootread/bootwrite`、`Set EXT_CSD_BOOT_CONFIG`）、SPI-NAND/NOR |

### 3.2 新增命令

| 命令 | 功能 |
|---|---|
| `ddr training` / `ddr tr/wl/gate/dataeye/vref/hw/mpr/ac/log` | DDR 训练与调试 |
| `getinfo nand/spi/version/ddrfree` | 查询 Flash/版本/剩余 DDR |
| `bootmode` / `bootmoderead` | 查询启动介质 |
| `mmc bootread` / `mmc bootwrite` | eMMC boot 分区读写 |
| `mmc write.ext4sp` | **写 Android sparse 镜像**（`ext4_unsparse()`，fs/ext4 内实现），刷机包的关键 |
| `bootldr` / `bootss` | 分阶段引导/快照启动 |
| `update` | 升级流程（配合 U 盘刷机） |

### 3.3 环境变量机制

- 环境变量格式与 U-Boot 一致：**4 字节 CRC32 + `key=value\0`**（这也是我们生成 bootargs.bin 的依据）
- 扩展：`CONFIG_FILE_BOOTARGS_NAME "bootargs.bin"` —— 从 **U 盘根目录读 bootargs.bin**，CRC 校验后执行（临时覆盖环境）
- 扩展：`bootargs_512M/768M/1G/2G/1536M/3840M` 按内存容量选择；`recoverybootargs` 恢复环境
- 板级默认：`CONFIG_BOOTDELAY 1`、`CONFIG_ZERO_BOOTDELAY_CHECK`（Ctrl-C 可中断）、`CONFIG_SYS_LOAD_ADDR` = DDR+0x8000

### 3.4 板级与驱动

- `board/hi3798mx/`（board.c、eth_cfg_setup.c）—— MV100/300 系列板卡
- `drivers/mmc/himciv200.c`（海思 MMC 控制器）+ `mmc_ids_hi3798mvx.c`
- 海思时钟/复位/sysreg、显示与 PQ（`cmd_display.c`、logo `BOOT_GFX_DisplayLogoWithLayer`）
- 网络保留 `tftp/ping/bootp`（`eth_cfg_setup.c` 配置 PHY）

## 4. U-Boot 替代路线对比

| 维度 | A. 自编译 SDK fastboot | B. 链式加载 U-Boot | C. 直接替换 p1 |
|---|---|---|---|
| 工作量 | 低（改配置即可编译） | 中高（写 ARM32 histb 板级） | 高（还要 DDR 训练/BootROM 头） |
| 风险 | 低（与现镜像同构，可回滚） | 中（hiboot 仍兜底） | 高（刷坏需串口救砖） |
| 可维护性 | 中（老代码，但源码在手可改） | 高（可用 upstream 特性） | 高 |
| 可用新特性 | 可自行加命令（ext4load、boot.scr） | boot.scr/extlinux/FIT/ext4/网络 | 同 B |
| 前置条件 | 海思 SDK 源码 | 需移植 U-Boot 到 MV100 ARM32 | 最全 |

### 4.1 方案 A：编译 SDK 的 fastboot（推荐先做）

SDK 源码树即为 hiboot 源码（`source/boot/fastboot`，`board/hi3798mx`），流程：

```
cp configs/hi3798mv100/hi3798mdmo1g_hi3798mv100_cfg.mak ./cfg.mak
source ./env.sh
make menuconfig      # 可按需打开 CONFIG_CMD_EXT2/EXT4 等
make build -j4
# 产物：out/hi3798mv100/fastboot-burn.bin、bootargs.bin、hi_kernel.bin
```

可做的低成本改进：

1. 打开 `CONFIG_CMD_EXT2`/`CONFIG_CMD_EXT4` → 获得 `ext4load`，内核可放 ext4 的 /boot
2. 修改默认 `bootcmd` 为"先试 U 盘 bootargs.bin → 再试 eMMC"的容错逻辑
3. 增加 `boot.scr` 类似机制（加载脚本执行），把引导策略从固件里挪到可编辑文件
4. 打开 `CONFIG_CMD_FDT` → 启动时可改 DTB（例如切换 root= 而不改内核）

风险：海思 SDK 为厂商泄漏镜像，授权不明；构建链较老（可能需 gcc 4.x/特定 libncurses），建议容器化编译。

### 4.2 方案 B：hiboot 链式加载 U-Boot

hiboot 已具备 `go`（start application at address）与 `fatload`，因此可以：

```
fatload usb 0 0x08000000 u-boot.bin
go 0x08000000
```

要点：

- U-Boot 需按 **ARM32 + MV100 板级**编译，且 `TEXT_BASE` 选在不与 hiboot 冲突的 DDR 区域
  （hiboot 自身从 0x00C00000 起，内核默认载入 0x01FFFFC0，建议 U-Boot 用 0x08000000 以上）
- 可 `CONFIG_SKIP_LOWLEVEL_INIT` 跳过 DDR 初始化（hiboot 已完成），但 U-Boot 仍需：
  时钟/复位（crg）、串口（pl011，可直接用 generic）、MMC（himciv200 需移植，或改用 dw_mmc 兼容驱动）
- 主线 `arch/arm/mach-histb` 只支持 `ARCH_HI3798MV2X`（ARM64），**需新增 ARM32 mach-histb 板级**；
  可参考 SDK `board/hi3798mx` 与 `include/configs/hi3798mx.h` 的寄存器基址
- 收益：拿到 boot.scr/extlinux/FIT/ext4load/tftp 全套现代引导能力
- 代价：一次性移植成本；之后维护成本明显低于改 hiboot

### 4.3 方案 C：直接替换 p1

需要把 U-Boot 做成 BootROM 可识别的镜像（私有头 + DDR 训练 + 时钟初始化），
等价于自己实现一个 hi3798mv100 的 SPL。除非有明确的长期维护计划，否则不建议。

## 5. 对当前项目的建议

1. **短期（保持现状）**：继续使用 hiboot + 环境变量方案。当前引导链（p6 裸分区内核 + p9 ext4 根）
   已经验证可用，不需要为此改 bootloader。
2. **中期（成本最低的改进）**：把 SDK fastboot 源码以子模块方式纳入仓库，做最小补丁：
   打开 ext4load/fdt 命令、把 bootcmd 改成"U 盘脚本优先"的可维护形态，CI 里一并编译
   （与现有 `fastboot.bin` 同构，回滚容易）。
3. **长期（可选）**：评估方案 B，把 U-Boot 作为 payload 由 hiboot 加载，逐步把引导策略迁到 boot.scr。

## 6. 风险与未验证项

- [ ] SDK 源码为社区镜像，授权/合规性需自行评估
- [ ] 方案 A 用现代 gcc 编译老 U-Boot 3.3.0 可能有兼容问题（需实测）
- [ ] 方案 B 的 U-Boot ARM32 板级移植工作量大，尚未验证可行性
- [ ] hiboot 的 `go` 是否会关闭 MMU/Cache、以及跳转前的中断/时钟状态未实测
- [ ] BootROM 私有头（"YZC"）格式未完全逆向，方案 C 暂无可行路径

## 7. 证据索引

- 二进制：`mv100/fastboot.bin`（539272 字节，2025-08-26）、顶层 `fastboot.bin`（539264 字节，2022-10-04）
- 源码（海思 SDK 镜像 https://github.com/zjkanjie/HiSTBLinuxV100R005C00SPC060 ）：
  `source/boot/fastboot/`（U-Boot 树）、`board/hi3798mx/`、`include/configs/hi3798mx.h`、
  `common/cmd_ddr_training.c`、`common/cmd_getinfo.c`、`common/cmd_mmc.c`（`write.ext4sp`）、`fs/ext4`
- 主线：`arch/arm/mach-histb/Kconfig`（仅 `ARCH_HI3798MV2X`）
