# 032 — 以原厂 Recovery 为第一突破口的主线 Linux HDMI 显示研究计划

> 2026-11-08 立项。用户给定研究纲领，本文把它落成项目内的正式路线，
> 并记录第一阶段的第一手技术突破。
>
> **定位**：本项目明确采用**主线 Linux 内核（ARMv7）**作为最终运行环境；
> **不再以社区版 Linux 为研究基础**，也不修补 / 沿用社区版 Linux 的显示方案。
> 核心方向：**从原厂 Recovery 入手，逆向还原 HDMI 显示驱动及初始化机制，
> 最终实现 ARMv7 华为悦盒在主线 Linux 内核下的原生 HDMI 显示支持。**
>
> 相关文档：`docs/015`、`docs/020`–`docs/024`、`docs/025`、`docs/027`、
> `docs/028`、`docs/029`、`docs/030`、`MAINLINE-PORTING.md`

---

## 0. 结论先行（本轮坐标）

1. 原厂 recovery **能显示**、原厂 Android **能显示** → 硬件与「出厂可用的初始化序列」客观存在，
   这不是「能不能亮」的问题，而是「主线内核有没有复现那套序列」的问题。
2. 本项目此前对 recovery 内核侧的结论（`docs/023 §4`）是**靠 HiSTB SDK 源码推测**的，
   因为当时**没能从 zImage 里解出 vmlinux**（文档原话：「压缩流未能直接抽出 vmlinux」）。
   本轮已把这一障碍打通：**解出 8,227,512 B 带 kallsyms 符号表的 vmlinux**，
   内核侧从此可以「用实际刷入的固件二进制实证」，不再只靠 SDK 推测。
3. 一个必须先讲清的区别：recovery 内核的 console 只有 `ttyAMA0` + `ttyMTD,blackbox`，
   **没有 fbcon / VT 文字控制台**；它能显示界面靠 `/sbin/recovery` 用户态直接 blit
   `/dev/graphics/fb0`。因此「复现原厂能显示图片」≠「主线 Linux 显示 TTY 文字」——
   后者需要额外把 framebuffer 绑定到 fbcon。这是第二阶段必须补的一环。

---

## 1. 研究目标

以华为悦盒（EC6108V9C / Hi3798MV100）原厂 Recovery 为**首要研究对象**，
深入分析其 HDMI 显示功能的硬件初始化过程、驱动实现机制及相关软件依赖，
目标是在 **ARMv7 主线 Linux 内核**上实现原生 HDMI 显示输出，
使 Linux 能正常显示控制台文字及图形界面。

明确排除：不以社区版 Linux 为研究基础；不修补 / 沿用社区版 Linux 的显示方案。

## 2. 研究路线（三阶段）

### 第一阶段：优先研究原厂 Recovery

提取原厂 Recovery 镜像，分析其中的 Linux 内核、Device Tree、Ramdisk、内核模块及启动参数，
重点研究 HDMI 控制器、显示控制器、Framebuffer、VPU、时钟、复位、HDMI PHY 等组件。
通过反编译、日志分析、内核配置对比，尽可能还原 Recovery 实现 HDMI 正常显示的**完整初始化链路**。

### 第二阶段：把 Recovery 的显示能力移植到主线 Linux

在明确硬件初始化机制后，分析相关驱动与主线 Linux 内核架构的差异，
**优先寻找可复用的开源驱动或现有 DRM/KMS 驱动**；若存在可继承的 Bootloader Framebuffer，
也应验证。在此基础上完成必要的 Device Tree 配置、驱动移植或重新实现，
使主线 Linux 能**独立初始化** HDMI 显示硬件（不依赖 hiboot 遗留状态、不依赖原厂用户态）。

### 第三阶段：Recovery 仍无法解决时，再研究原厂 Android

进一步提取原厂 Android 的内核、驱动模块、Device Tree、系统服务及固件，
分析 Recovery 中可能未暴露的底层显示初始化机制；必要时逆向还原闭源驱动的硬件操作过程，
并把必要功能移植 / 重新实现到主线 Linux。

## 3. 研究原则

- 原厂 Recovery = 第一突破口；原厂 Android = 第二研究对象；主线 Linux = 最终目标。
- 重点是**还原原厂显示硬件的初始化逻辑**，并将其转化为主线 Linux 可独立使用的
  驱动与硬件配置；**不依赖原厂 Android 环境**、不继续使用社区版 Linux。
- 坚持「固件二进制实证」优先于「SDK 源码推测」；两者结论冲突时以实际刷入的固件为准。

## 4. 最终交付目标

1. 在 ARMv7 华为悦盒硬件上成功启动主线 Linux。
2. 实现 HDMI 正常输出画面，**而非仅依赖 Bootloader 显示静态图片**。
3. 实现 Linux 控制台文字显示。
4. 尽可能实现标准 Linux DRM/KMS 显示架构，为后续图形桌面及硬件加速提供基础。

---

## 5. 与既有工作的关系（不推翻，补空白）

| 既有资产 | 本计划的关系 |
|---|---|
| `docs/023` recovery 显示逆向 | 其 §4 因解不出 vmlinux 只能 SDK 推测；本计划用解出的带符号 vmlinux 把内核侧升级为**固件实证**；其 §4.2 VO 寄存器偏移、§4.3 `HDMI_Display()` 序列、§5.3 真机待确认清单全部继承并逐条证伪 / 证实 |
| `docs/027` 原厂整机备份静态分析 | 已用 strings / 常量证实显示驱动内建、无显示 `.ko`、寄存器基址、EDID 运行时读取；其 §7.2 把「反汇编提取精确寄存器写入序列」列为**尚未做**的下一步，本计划正是执行它 |
| `docs/025` / `docs/028` pmOS 方法论 | 「downstream 内核只读参考、mainline 用 DRM/KMS 重写」「初始化序列逐字节来自原厂资产，不要手写猜」仍是准则 |
| `docs/029` 发送器形态 | mv100 走 SiI9134 / MMIO `0x8ce0000`，`0xf8ce0000` 属 hi3716cv200；本计划的寄存器实证须与此对齐，用来校验 / 修正基址 |
| `docs/030` / `build-histb.yml` / `mainline-porting` | histb 上游 7.4 + 补丁是「别人在 EC6108V9C 上验证过的组合」，流水线已绿；本计划不取代它，而是为其补上**寄存器级硬件依据**，两条线合流到「主线 Linux 原生 HDMI」 |
| `patches/kernel/hi3798mv100-hdmi-console.c` | 6.3 时代的 simplefb 交接驱动，寄存器基址 / 偏移是手搓猜测；本计划的第一阶段实证应反过来校正它 |

---

## 6. 第一阶段第一手突破：解出带符号的 recovery vmlinux

### 6.1 之前为什么失败（可复现的坑）

对象：`TMP/p3_recovery.img`（16 MiB 原厂 recovery 分区，即 `backup_stock/p3_recovery.img.gz`
的解压产物）与从中抽出的 `TMP/rec-zImage`（2,822,584 B）。

- 旧脚本按 **gzip 魔数** `1f 8b 08` 找压缩流；但这份内核是 **xz** 压缩，
  魔数 `fd 37 7a 58 5a 00` → 找不到 piggy，`TMP/rec-vmlinux` 一直是 0 字节，
  `TMP/recovery-analysis.log §3 / §4` 因此「显示符号 / 字符串 = none」。
- xz 魔数在镜像里有**假命中**：`0x383f`（解压 stub 里的偶然字节）解压即
  `LZMAError: Corrupt input data`；**真正的 piggy 在 `0x391f`**。必须遍历所有魔数、
  逐个尝试解压、取能成功且最大的那个，不能见到第一个魔数就认定。
- `TMP/p3_recovery.img` 里还有**第二个 boot.img 槽**（`ANDROID!` @ `0x800000`），
  xz @ `0x80415f` 解出另一份 7,539,320 B 的 vmlinux —— 两个槽是不同构建，
  数值不可互引（`docs/027 §3.2` 已提示归档里 p03 有同类异常）。
- `p01` / p1 fastboot 与 `p03` recovery 的 ramdisk 都是 gzip，唯独 recovery kernel 是 xz，
  这也是旧脚本「boot.img 能解、kernel 解不开」的原因。

### 6.2 解出的事实

| 项 | 值 |
|---|---|
| 压缩 | xz，piggy @ `0x391f`（相对 `rec-zImage`） |
| vmlinux | **8,227,512 B**，ARM 内核入口（`16 2d 00 eb ...`） |
| 版本 | `Linux version 3.10.0_s40`，2016-12-15，HiSilicon gcc 4.4.1，`linux-3.10.y` SDK |
| 字符串 | 46,992 条（去重 38,673），**含 kallsyms 符号名** → 可做符号级反汇编 |
| 源码路径 | vmlinux 内含 SDK `linux-3.10.y` 的 `__FILE__` 路径，可定位驱动文件组织（厂商构建机信息按隐私红线省略） |

产物在 `TMP/recovery-deep/recovery-vmlinux.bin`（`TMP/` 已 gitignored，不入库）。

### 6.3 显示驱动全景（vmlinux 字符串实证，非 SDK 推测）

| 组 | 命中 | 代表符号 |
|---|---|---|
| HDMI TX | 355 | `HI_DRV_HDMI_Init/Open/Close`、`DRV_HDMI_Read_EDID`、`DRV_HDMI_Force_GetEDID`、`DRV_HDMI_SetVOAttr`、`DRV_Calculate_TMDSCLK`、`HDMI_ModeInit`、`HDMI_DRV_ModInit`、`hdmi_ProcEvent`、`hdmi_MCE_ProcHotPlug` |
| EDID / DDC | — | `SI_ReadEDID`、`SI_ReadSinkEDID`、`SI_Proc_ReadEDIDBlock`、`SI_DDC_ResetTV`、`SI_Force_GetEDID`、`ConvertMDDCStateIntoErrCode` |
| VO / VDP / DISP | 792 | `HI_DRV_DISP_Init`、`DISP_HAL_Init/GetOperation`、`DRV_DISP_Register`、`DISP_ExtAttach/Open`、`DISP_GetTimingReg`、`PF_VDP_RegSave/RegReStore`、`PQ_HAL_WBC_*` |
| Framebuffer | 65 | `FBIOGET_CAPABILITY_HIFB error`、`failed to register_framebuffer!`、`register_framebuffer` / `unregister_framebuffer` |
| 参数 / 基础 | 575 | `HI_DRV_PDM_Init`、`PDM_DRV_ModInit`、`DRV_PDM_*`、`HI_DRV_GPIO_*`、`HI_DRV_SYS_GetChipVersion` |
| 时钟 / 复位 | 183 | `clk_set_rate`、`mach-hi3798mx/clock.c`、`enable clock:%s failed`、`sp804` 时钟 |
| DDC 通道 | 46 | `hi_gpio`、`/dev/hi_i2c`、`I2C transaction did not start ...`、`MDDCState:I2C_LOW` |

**寄存器 4 字节常量计数**：`0xf8cc0000` 2 处、`0xf8ce0000` 1 处、
`0xf9000000` 40 处、`0x08ce0000` 0 处。内核多用 ioremap 动态映射，
基址常量命中少属正常；`0xf9000000` 大量命中值得进一步查（VO/VDP 备用区，见 `docs/027 §4.2`）。

**`SI_*` / `SiI_*` 前缀的意义**：`docs/027 §6` 曾以「全库 `sii9134` 字面量 0 命中」
质疑外挂发射器；这里 `SI_ReadEDID` 等函数族 + hiboot 的 `siiSetVideoPath` /
`SiI_DeepColor_*` 说明 SDK 用 `SI_` / `SII_` 前缀封装 Silicon Image 发射器 IP，
**不带 `sii9134` 字样不等于没有该 IP** —— 与 `docs/029` 的 bridge 链路结论同向，
应作为补强证据。

### 6.4 启动参数与 console（关键区别）

vmlinux 里的 cmdline 痕迹：

```
console=ttyAMA0,115200 blkdevparts=mmcblk0:1M(fastboot),4M(bootargs),16M(recovery),...
coherent_pool=2M mem=1G console=ttyAMA0,115200 initrd=0x2500000,0x1300000 mmz=ddr,0,0,256M root=/dev/ram ...
mem=1G mmz=ddr,0,0,380M   (bootargs_1G)
ERR: no bootargs env!   bootargs crc failed !   recoverybootargs
```

- `mmz=ddr,...` 是媒体内存区（MMZ），显示 / 解码共用 → 主线侧对应 `reserved-memory` / CMA。
- console **只有 `ttyAMA0`（串口）与 `ttyMTD,blackbox`**；字符串里虽有
  `register_console` / `console [...] enabled`，但没有 fbcon 绑定到图形设备的证据。
- 结合 `docs/023 §3`：`/sbin/recovery` 用 `open("/dev/graphics/fb0")` +
  `FBIOGET_*SCREENINFO` + `KDSETMODE/KD_GRAPHICS` 直接 blit `res/images/*.png`。
- → **原厂「能显示」= 内核 hifb 注册 fb0 + 用户态画 PNG；
  主线「显示 TTY 文字」= 还需要 fbcon / VT 绑定**。第二阶段不能只复现前者。

---

## 7. 待验证清单（把 `docs/023 §5.3` 升级为可证伪问题）

基于带符号 vmlinux，以下都可以从反汇编给出确定答案，不再靠猜：

1. `HDMI_DRV_ModInit` / `HI_DRV_HDMI_Init` / `HI_DRV_HDMI_Open` 的真实调用链与寄存器写入顺序，
   与 `docs/023 §4.3` 的 SDK 序列逐条核对（EDID → AVI InfoFrame → `TX_PHY_*` → `TX_SetHDMIMode`）。
2. `HI_DRV_DISP_Init` / `DISP_HAL_Init` 如何配置 VO 图层（`G0_ADDR` +0x494 /
   `G0_STRIDE` +0x49c / `G0_IRESO` +0x4a0），以及用的是 G0 还是 GP0 层。
3. hifb 注册 `/dev/graphics/fb0` 时的显存来源（MMZ）、格式、stride、分辨率；
   与社区内核实测的 `smem_start` / 1920x1080 ARGB8888 / stride 7680 对照。
4. 时钟与复位：显示相关 clk 名、`clk_set_rate` 调用点、CRG 寄存器；
   对应主线 `clk_ignore_unused` 是否够、还是需要主动 `clk_get/enable`。
5. EDID / HPD：`SI_ReadEDID` 走发射器自带 DDC 还是 GPIO bit-bang I2C；
   对应主线 `drm_edid` 或自写 DDC 的选择。
6. 是否有可继承的 Bootloader framebuffer（hiboot 画的 logo 帧缓冲），
   以及主线 simplefb / `simple-framebuffer` 能否直接接管（`docs/023 §5.2` 第一阶段）。
7. vmlinux 里 `0xf8ce0000` / `0xf8cc0000` / `0xf9000000` 的实际 ioremap 用途，
   与 `docs/029` 的 `0x8ce0000`（mv100 SiI9134）关系：是同 SoC 不同映射窗口，
   还是 SDK 多 chip 条件编译残留。

---

## 8. 验收标准

按 §4 四条逐项验收；其中「HDMI 输出画面」与「控制台文字」必须**由主线内核独立初始化**
产生，不能用 hiboot 静态 logo 或刷机链尾部的 logo 冒充。
在无串口硬件的约束下，可观测手段限于：HDMI 画面、SSH / 网络、pstore / ramoops、
以及刷机前后分区内容核对（`docs/028`、`docs/024`）。

---

## 9. 方法与合规

- 全程**离线静态分析**（解包 / 解压 / 反汇编 / 符号与常量扫描 / 交叉引用）；
  不刷机、不改真机、不联网、不在本机构建 rootfs / 系统镜像（构建一律交 CI）。
- 临时产物统一放项目内 `TMP/recovery-deep/` 等 `TMP/` 子目录（已 gitignored）；
  **不删除文件、不 `git clean`、不访问项目目录之外的目录**。
- 描述本地资源一律用仓库内相对路径或通用占位；
  **不得写入本机绝对路径 / 用户名 / 卷名**，厂商构建机路径与构建用户标识一律省略。
- 结论严格区分「二进制实证」与「推测」，不确定处标存疑，不编造寄存器值。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；
  纯 `docs/` 改动不触发任何 build workflow。
