# vendor-display — 海思私有显示栈 backport 到 6.3 主线内核（补丁清单）

> 方案见 `docs/052-mainline-kernel-vendor-driver-plan.md`。本目录放 backport 驱动与补丁。
> 目标：6.3 主线内核（提供主线 ABI/功能），显示驱动用海思私有栈（不要求主线驱动）。
> 网卡保持主线 hisi_femac，不在本目录范围。

## 状态（诚实）
- **当前：占位，驱动尚未写入，但寄存器初始化序列已交付**（全量反汇编产物已归档于
  `research/full-disasm/`，见 `reg_init_sequence.md` §2 最小可落地清单 + `FINDINGS.md §D` 偏移定音）。
  `DISPLAY_DRIVER=vendor-backport` 仍会 fail-fast：缺 `hi3798mv100_vendor_display.c` +
  `0004-...patch`，写好后即解除。
- 序列落地不手写猜寄存器值（docs/025 §2.2 铁律）：可直接写成 `writel` 表的确定性静态序列有
  `reg_init_sequence.md` 的**序列 A（HDMI PHY 7 写，含 reg5=0x04）、序列 B（CRG 复位 5 写 + 3 Delay）、
  `ACR_CTRL=0x04`**；RMW / fb_base / EDID / 时序一律运行时算、标 [推断]/[未知]。
- **更靠前的前置仍是"6.x 内核到底起没起"**（`research/full-disasm/UNKNOWNS.md` 优先级 0）：
  给没启动的内核调显示驱动无意义。先真机绿带 / pstore / 新 IP 确认，再谈显示。

## 要 backport 的源码（HiSTB SDK `TMP/sdk-src/`，只取寄存器写入序列，不整目录照搬 MPP 框架）
| 来源 | 取什么 | 用途 |
|---|---|---|
| `source/boot/product/driver/pdm/drv_pdm.c` | `g_stDispTiming`、`ClkPara0=0x912ccccc`/`ClkPara1=0x006d8157`、接口类型 | DISP/VO 硬编码显示时序（1080p60 fallback；实际时序运行时从 EDID） |
| `source/boot/product/driver/graphic/gfx/hi_gfx_layer.c` | `BOOT_GFX_DisplayLogoWithLayer` 的 `G0_ADDR`/`G0_STRIDE`/`G0_IRESO` 写入序列 | GFX 图层配置（地址/格式/stride/enabled） |
| `source/boot/product/driver/hdmi/hdmi_1_4/{de,hdmitx,phy,infofrm}.c` | HDMI TX / PHY 寄存器初始化、`HDMI_Display()`、`TX_PHY_WriteRegister` | HDMI 输出点亮 + AVI InfoFrame |
| `source/msp/drv/{vo,hifb}/` + `hi_reg_vdp.h` | 寄存器结构体定义、偏移交叉验证 | **偏移已定死（见下 §偏移一锤定音）**：`G0_ADDR=+0x6010` 系列为真值；`+0x494` 系列是压缩视图误算，弃用 |

寄存器基址（docs/027 §4.2 二进制实证）：VO/VDP `0xf8cc0000`、HDMI TX `0xf8ce0000`、VDP 备用 `0xf9000000`。

> ### 偏移一锤定音（[观察]，见 `research/full-disasm/FINDINGS.md §D`）
> 三份真内核（正常 3.10 / recovery 3.10 / 社区 4.4）`VDP_GFX_SetLayerAddr` 等反汇编 +
> SDK `hi_reg_vdp.h` 全 struct（含全部 `Reserved_*`）逐字段累加，双 oracle 一致：
> - **`addr(layer N) = 0xf8cc0000 + 0x6010 + (N<<11)`**，`N*0x800 = CONFIG_HIFB_GFX_OFFSET`（mv100=0x800）。
>   `G0_CTRL=+0x6000 / G0_UPD=+0x6004 / G0_ADDR=+0x6010 / G0_NADDR=+0x6018 /
>   G0_STRIDE=+0x601c / G0_IRESO=+0x6020`（全结构 0xf354 B = 15573 u32）。
> - **旧 `+0x494` 系列弃用**：那是丢掉 `Reserved_57[1840]` 等保留空洞后"605 u32 / 0x974 窗口"
>   的压缩视图计算错误（与 docs/023 §4.2 自述逐字吻合），**不是另一套硬件窗口**；
>   full-struct 下 `+0x490=GP0_PARARD`、`+0x494=GP1_PARARD`（GP 层参数读寄存器），根本不是 G0_ADDR。
> - **ioremap**：`CONFIG_VDP_SIZE=0xfff0`（SDK 值，建议直接采用）；只读 layer0 ≥`0x7000`，
>   读写全部 6 层（layer5 IRESO=0x8820）≥`0x9000`。
> - **legacy `patches/kernel/hi3798mv100-hdmi-console.c` 有双重错误**：`:53 VO_REG_SIZE=0x1000`
>   够不到 +0x6010，`:54-56` 读的是 `+0x494`(=GP1_PARARD)。[推断] 必读不到有效显存——
>   这解释了短接态"VO G0 三寄存器=0"（docs/050:925）。改 B 组 + ioremap `0xfff0`
>   （真机确认前未改该文件；该文件属 legacy simplefb 路线，本方案不依赖它）。
>
> **仍 [未知] 待真机**：正确偏移 `0xf8cc6010` 上此刻的 MMIO 读值、它是否等于
> `HIFB_DispBuf_HD`(=0x3f6ce000)、跨次稳定性、双缓冲第二帧是否在该预留区。
> 偏移本身已定死（[观察]），只剩真机读值未定——backport 驱动按上表落地寄存器定义即可。

## 4.4 → 6.3 API 适配点（docs/021 §3/§4）
- SDK 裸 MMIO → 主线 `ioremap` + `readl/writel`。
- clk/reset → 主线 `crg` provider（`CONFIG_COMMON_CLK_HI3798` / `CONFIG_RESET_HISI`）。
- 显存 → `alloc_pages` / `reserved-memory`，或复用 MMZ 语义；双缓冲两帧都覆盖（docs/040）。
- 注册 → 主线 `fbdev`（`drivers/video/fbdev/`）或 `drivers/gpu/drm/hisilicon/` DRM；
  `console=tty0` + `fbcon=map:0`（已在 cmdline/config 就绪）输出内核日志。
- 时序：运行时 EDID（HPD + DDC/I2C），不依赖 hiboot 遗留显存地址（这是与 legacy simplefb 路线的根本区别）。

## 挂载点（补丁）
- `0004-vendor-display-kconfig-makefile.patch`：`drivers/video/fbdev/Kconfig` + `Makefile`
  加 `CONFIG_HI3798MV100_VENDOR_DISPLAY`（或 DRM 路径）。
- `hi3798mv100_vendor_display.c`：platform driver，`subsys_initcall`/`module_init` 完成初始化；
  复用已内置的绿带 boot marker 语义（证明内核起来了，属 L0 探针，见 docs/052 §5）。
- `CONFIG_HI3798MV100_VENDOR_DISPLAY=y` **不要写进共用的 `configs/kernel/ec6108v9c.config`**
  （simplefb 默认路径也读它，会被污染 / 触发不存在的符号）。已由 `scripts/build-kernel.sh`
  在 `DISPLAY_DRIVER=vendor-backport` 分支里用 `scripts/config -e` 条件式 enable（在
  `.config` 合并后、`olddefconfig` 前），符号缺失时 olddefconfig 自动丢弃，对默认路径无害。

## 接线（已改）
- `.github/workflows/build-release.yml`：`display_driver` input（`simplefb` 默认 / `vendor-backport`），
  `build-kernel` job 传 `DISPLAY_DRIVER`。
- `scripts/build-kernel.sh`：`DISPLAY_DRIVER=vendor-backport` 分支应用本目录补丁、复制驱动、
  跳过 simplefb 占位注入；驱动未就绪 fail-fast。默认 `simplefb` 路径不变，CI 不破坏。

## 判据
- 编译：CI 出 `hi_kernel.bin`（6.3 + 新驱动），`grep CONFIG_HI3798MV100_VENDOR_DISPLAY=y`。
- 真机：绿带 / 启动文字 / IP（docs/052 §5）。内核是否起来是前置：静态反汇编不能判定，必须真机信号。
