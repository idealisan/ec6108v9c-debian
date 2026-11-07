# 022 — HDMI 驱动移植设计（SDK 源码提取结果）

> 配套 `docs/021-hdmi-driver-porting.md`。本文是把 HiSTB SDK 显示栈源码拉到
> `TMP/sdk-src/` 后逐文件提取的**寄存器基址、初始化序列、依赖边界**，
> 作为写 6.x platform driver 的依据。所有数值来自源码，不是探测。

---

## 1. 社区版为什么参考价值低（用户判断 + 源码佐证）

用户观察：社区 Ubuntu 开机只显示一个广告画面，**不显示 TTY**。若内核真的
接管了显示，按常理应能输出 framebuffer console。

实测与源码都印证：

| 证据 | 结论 |
|---|---|
| 系统无用户态显示程序/服务 | 没人往 fb 画东西 |
| `/dev/fb0` 读出内容全 0 / 全 0xff | 空白缓冲，非 UI |
| `HDMI kernel event(no UserCallBack): HOTPLUG` | 热插拔事件无处理者 |
| `/proc/iomem` 全 System RAM，无 reserved 显示区 | 显存是运行时分配的，非预留 |
| 多次重启有时亮有时不亮 | 遗留状态不稳定 |
| `HI_UNF_HDMI_Start()` / `HI_DRV_HDMI_Init()` 在 SDK 里是**空壳**（只打印 in/out 后 return） | 内核侧没有持续的 HDMI 驱动工作 |
| 真正干活的只有 `HI_UNF_HDMI_Open()` → `HDMI_Display()` | hiboot 里**一次性**寄存器配置 |

**结论**：社区内核虽内建 hifb 并注册 `/dev/fb0`，但没有接 fbcon、没有用户态刷新；
屏幕上挂的是 hiboot 画完的 logo 残留。**不能把社区内核当作"已验证的显示实现"来照搬**，
应直接以 SDK 的 hiboot 显示栈为准。

---

## 2. 源码范围与规模

来源 `zjkanjie/HiSTBLinuxV100R005C00SPC060` @ `a9f05973129d738e175416dd4a91b2c264ffcdd4`，
已下载 226 个文件（2.0 MiB）到 `TMP/sdk-src/`，清单在 `TMP/sdk-download-list.txt`，
目录树快照在 `TMP/sdk-tree.json`。

| 路径 | 用途 |
|---|---|
| `source/boot/product/driver/hdmi/hdmi_1_4/` | HDMI TX 1.4 驱动（本机芯片走这个） |
| `source/boot/product/driver/hdmi/hdmi_2_0/` | HDMI 2.0 变体（由 `CFG_HI_HDMI_SUPPORT_2_0` 选择） |
| `source/boot/product/driver/graphic/gfx/` | GFX 图层 / 显存 / surface |
| `source/boot/product/driver/graphic/dec/` | logo 图片解码（BMP/JPEG） |
| `source/boot/product/driver/pdm/drv_pdm.c` | PDM 预留内存、显示参数、EDID fallback |
| `source/boot/product/driver/include_inc/hi_drv_disp.h` | DISP 接口声明 |
| `source/boot/fastboot/lib/reserve_mem.c` | 预留内存布局 |
| `source/msp/drv/vo/vdp_v4_0/` | 完整 MPP VO（477 个文件，暂不移植） |
| `source/msp/drv/hdmi/hdmi_1_4/hdmi_drv/` | 完整 MPP HDMI（暂不移植） |

编译选择（`source/boot/product/driver/hdmi/Makefile`）：
`CFG_HI_HDMI_SUPPORT_1_4=y` → `hdmi_1_4`；`..._2_0=y` → `hdmi_2_0`。

---

## 3. 静态寄存器基址（无需探测）

`hdmi_1_4/drv_reg_proc.h`，条件分支明确包含 **`CHIP_TYPE_hi3798mv100`**：

```c
#define HDMI_TX_BASE_ADDR       0xf8ce0000L   /* HDMI TX SLV0 */
#define HDMI_TX_SLV0_ADDR_BASE  0xf8ce0000L
#define HDMI_TX_SLV1_ADDR_BASE  0xf8ce0400L
#define HDMI_TX_CEC_ADDR_BASE   0xf8ce0800L
#define HDMI_TX_PHY_ADDR        0xf8ce1800L
#define HDMI_REG_WRITE(addr,val) (*(volatile unsigned int *)(addr) = (val))
#define HDMI_REG_READ(addr)      (*(volatile unsigned int *)(addr))
```

这与 `rootfs/usr/local/bin/ec6108-fbprobe` 里扫描的 `0xF8CE0000` 范围一致，
VO/VDP 区 `0xF9000000-0xFA000000` 则来自 fbprobe 的既有定义。
在 6.x 驱动里用 `ioremap()` 映射这两段即可，不需要 mmap `/dev/mem`。

---

## 4. HDMI 初始化序列（从 `hdmi_1_4/hdmi.c` 提取）

入口链：`HI_UNF_HDMI_Open()` → `HDMI_Display()`。
`HI_UNF_HDMI_Init()` 只做 `HW_ResetHDMITX()` / `SW_ResetHDMITX()` /
`TX_PHY_PowerDown(HI_TRUE)`；`Start()` 是空壳。

`HDMI_Display()` 关键顺序：

1. `HI_UNF_HDMI_GetSinkCapability()` —— **读 EDID**，拿到 sink 的 preferred timing
2. 按 `enHdFmt`（`HI_UNF_ENC_FMT_1080P_60` 等）设置 colorimetry / aspect / pixel repetition
3. `UpdateTX_656()` → `SetIClk(0)` → `WakeUpHDMITX()`
4. `siiSetVideoPath()` / `SetIClk()` / 配置 AVI InfoFrame、VIC（`1920X1080P_60000` = `0x51,0xaa,...`）
5. PHY：`TX_PHY_HighBandwidth()`、`TX_PHY_SwingCtrl()`（4K 用 SWING_300M，普通用 SWING_NOMAL）
6. `TX_SetHDMIMode(hdmi_dvi_mode)` → 使能 CP/AVI InfoFrame
7. **`TX_PHY_EnableHdmiOutput()`** —— 最后打开输出

对应函数分布在 `hdmi_1_4/`：`hdmi.c`（主流程）、`hdmitx.c`、`phy.c`、
`de.c`、`infofrm.c`、`si_vmode.c`、`vmtables.c`、`txvptbl.c`、`si_edid.c`。

### 时序来源（重要）

`hdmi.c` 第 90-108 行：显示时序**取自 EDID 的 `SinkCap.stPerferTiming`**
（VFB/VBB/VACT/HFB/HBB/HACT/VPW/HPW/PixFreq 等）。
`drv_pdm.c` 里的 `g_stDispTiming`（1366x768、ClkPara0=0x912ccccc）只是
`HI_LOADER_SUPPORT` 下的 **fallback**，不是 1080p60 的实际配置。

→ 驱动必须实现 **HPD 检测 + EDID 读取**，或至少在 EDID 不可用时用一张
固定的 1080p60 时序表（可从 `si_vmode.c` / `vmtables.c` 提取）。
这也解释了社区系统重启后有时不亮：`HDMI HOTPLUG no UserCallBack`，
HPD/EDID 路径没有闭环。

---

## 5. GFX 图层 / 显存

- `hi_gfx_mem.c`：`BOOT_GFX_RESERVE_Alloc()` 调 `HI_DRV_PDM_AllocReserveMem()`
  从 **PDM 预留内存**分配显存；另有 `BOOT_GFX_MMZ_Alloc()`
- `hi_gfx_layer.c`（951 行）：`BOOT_GFX_DisplayLogoWithLayer()` /
  `GFX_CreateLayer()` / `GfxOpenLayer()` / `GFX_RefreshLayer()`，
  引用 `HI_DRV_DISP_*`、`drv_hifb_adp.h`、`drv_disp_ext.h`
- `hi_gfx_surface.c`、`hi_gfx_show.c`：surface 与显示入口
- **依赖边界**：graphic 栈调用了 `source/msp/drv/` 的 API（如
  `HI_DISP_GetDisplayInfo`），**不能整目录照搬到 6.x**；
  只取其中的**寄存器写入序列**，用主线 `ioremap/readl/writel` 重写

### 图层配置接口与像素格式（源码确认）

`source/msp/drv/hifb/adp/inc/drv_hifb_adp.h` 的 `HIFB_DRV_OPS_S`：
`HIFB_DRV_SetLayerAddr(layer, addr)` / `SetLayerDataFmt()` /
`SetLayerAlpha()` / `UpdataLayerReg()` —— 图层地址/格式/刷新都是这些回调。
`hi_gfx_layer.c:868` 调 `OPTM_GfxSetLayerAddr(DataId, pPhyAddr[InUsingDispIndex])` 设置显存地址。

`optm_define.h` 的 `VDP_GFX_IFMT_E` 给出格式枚举（24bpp `RGB_888=0x50`、
ARGB1555/8888 等），`OPTM_VDP_LAYER_GFX0..5` 是图层号。
这些是**移植时直接照抄的常量与调用顺序**，不需要猜寄存器偏移：
把 `HDMI_REG_WRITE` / `OPTM_*` 的物理地址访问换成 `ioremap + writel` 即可。

### 社区系统量到的 fb0 参数（仅供参考，不是目标地址）

| 项 | 值 |
|---|---|
| `smem_start` | `0x3c55c000`（965 MiB） |
| `smem_len` | `0xfd2000`（15.8 MiB，双缓冲） |
| `xres/yres` | 1920x1080 |
| `virtual_size` | 1920x2160 |
| `bpp / format` | 32 / `a8r8g8b8` |
| `stride` | 7680 |

这块是社区内核 hifb 运行时从普通 RAM 分配的（iomem 无 reserved 区），
**不是 hiboot logo framebuffer**，不能填进我们的 simplefb DTS。
新驱动应**自己分配显存**（`reserved-memory` + `no-map` 或 `alloc_pages`）。

---

## 6. 6.x 驱动结构（设计草案）

`drivers/video/fbdev/hi3798mv100-hdmi.c`（或 `drivers/gpu/drm/` 下），
platform driver（`compatible = "hisilicon,hi3798mv100-hdmi"`）：

```
probe:
  ioremap 0xf8ce0000 (HDMI TX), 0xf8ce1800 (PHY), 0xf9000000 (VO/VDP)
  clk_get/enable 所需时钟 (且保留 clk_ignore_unused 兜底)
  HPD/EDID: 读 sink preferred timing; 失败则用内置 1080p60 表
  DISP/VO: 按 timing 配接口(HDMI RGB888)、写入 VO 层地址/格式/stride/使能
  HDMI TX: 按 §4 顺序写寄存器, 最后 TX_PHY_EnableHdmiOutput()
  alloc 显存 (1920*1080*4 = 8MiB, 或双缓冲 16MiB), reserved-memory no-map
  platform_device_register 一个 "simple-framebuffer":
     resource IORESOURCE_MEM = 显存物理地址+大小
     simplefb_platform_data = {1920, 1080, 7680, "a8r8g8b8"}
  -> fbcon 接管, console=tty0 输出内核日志
```

复用已有改动：`console=tty0`、`CONFIG_FB_SIMPLE` / `FRAMEBUFFER_CONSOLE` / `VT`、
字体、`clk_ignore_unused`、pstore 日志兜底、simplefb 几何参数化的 CI 输入。

### 待确认（写驱动前需从源码补齐）

- [ ] `si_vmode.c` / `vmtables.c` 里 1080p60 的完整时序与 PHY 参数表
- [ ] VO/VDP 寄存器中「GFX 层地址 / stride / 格式 / 使能」的准确偏移
      （在 `source/msp/drv/vo/vdp_v4_0/` 的寄存器头文件里）
- [ ] HPD/EDID 读取在 6.x 下走 `drm_edid` 还是自己实现简易 I2C/DDC
- [ ] 所需时钟名字（crg 里 VO/HDMI/VDP 的 clock id）
- [ ] 是否需要 `reserved-memory` 节点把显存从内核内存里排除

---

## 6.1 第一版驱动已落地并编译通过（2026-11-07）

`patches/kernel/hi3798mv100-hdmi-console.c`（194 行，built-in bool 驱动，
`subsys_initcall`）：

- `ioremap` HDMI TX `0xf8ce0000`/VO `0xf9000000`（VO 只扫前 64 KiB，
  避免 external-abort 页 oops）
- `get_kernel_nofault()` 安全读 32-bit 寄存器，找 4 KiB 对齐的 DDR 地址
  （hiboot 写进 VO 层地址寄存器的显存）
- `memremap` 校验该地址有像素内容
- 用 `simplefb_platform_data` + `IORESOURCE_MEM` 动态注册
  `simple-framebuffer` platform device，fbcon 接管
- **不重新初始化显示硬件**（会重置 hiboot 状态导致黑屏，
  postmarketOS 的 display-clock 教训）

挂接：`0003-hdmi-console-kconfig-makefile.patch`（Kconfig bool + Makefile）、
`CONFIG_FB_HI3798MV100_HDMI_CONSOLE=y`、`build-kernel.sh` 加入补丁列表与 cp。
已有 `console=tty0` / `CONFIG_FB_SIMPLE` / `FRAMEBUFFER_CONSOLE` / `VT` 直接复用。

**CI 验证**：run `42361378514` 两个 job 全绿，日志确认
`applied: 0003-...` 和 `CC drivers/video/fbdev/hi3798mv100-hdmi-console.o`，
release `build-20261107T102931Z` 已产出。

**本机 docker 验证**：OrbStack + `debian:bookworm-slim` +
`gcc-arm-linux-gnueabihf`，脚本 `TMP/docker-build-check.sh`（源码 read-only 挂载、
容器内联编）。本机同样能编内核，只是比 CI 慢；CI 作为权威产物。

**注意**：第一版是"保留 hiboot 状态"的最小路径。若真机上扫描不到
framebuffer 地址，驱动会 warn 后退出（不破坏启动），此时按 §6 走
自己分配显存 + 按 SDK 序列初始化 HDMI TX 的第二阶段。

## 7. 验证前提（与刷机流程绑定）

驱动编进内核后要真机验证，必须同时让刷机流程能走完：
rootfs 镜像 1 GiB → 256~512 MiB（首启 `resize2fs` 扩容）、
`loadfiler` 补 `getinfo ddrfree`、`flashpartitionr` 长度同步缩小。
否则永远卡在刷机流程、不 `reset`、屏幕不亮。
详见 `TMP/刷机失败排查说明.txt` 与 `docs/018` §10。

---

## 8. 参考

- `docs/021-hdmi-driver-porting.md`：路线决策与 SDK 盘点
- `docs/020-hdmi-display-porting.md`：simplefb 备选路线
- `docs/004-hiboot-vs-uboot-analysis.md`：hiboot 板级驱动线索
- postmarketOS SDM845 Mainlining：simplefb + `display clocks disabled` 的通用做法
  （提醒：内核显示时钟重新初始化会重置 bootloader 设好的状态导致黑屏，
  与我们的 `clk_ignore_unused` 一致）
- `TMP/sdk-src/`：本次下载的 SDK 显示栈源码
- `TMP/sdk-tree.json` / `TMP/sdk-download-list.txt`：源码定位与清单
- `TMP/fb-report-1.txt`：社区系统 framebuffer 采集报告（含教训）
