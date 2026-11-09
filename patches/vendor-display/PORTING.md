# vendor-display — 海思私有显示栈 backport 到 6.3 主线内核（补丁清单）

> 方案见 `docs/052-mainline-kernel-vendor-driver-plan.md`。本目录放 backport 驱动与补丁。
> 目标：6.3 主线内核（提供主线 ABI/功能），显示驱动用海思私有栈（不要求主线驱动）。
> 网卡保持主线 hisi_femac，不在本目录范围。

## 状态（诚实）
- **当前：占位，驱动尚未写入。** 依赖研究员全量反汇编 `TMP/stock-rom-research/full-disasm/`
  产出的寄存器初始化序列。`DISPLAY_DRIVER=vendor-backport` 会 fail-fast 并指向本文。
- 序列到位后按下面清单落地，不手写猜寄存器值（docs/025 §2.2 铁律）。

## 要 backport 的源码（HiSTB SDK `TMP/sdk-src/`，只取寄存器写入序列，不整目录照搬 MPP 框架）
| 来源 | 取什么 | 用途 |
|---|---|---|
| `source/boot/product/driver/pdm/drv_pdm.c` | `g_stDispTiming`、`ClkPara0=0x912ccccc`/`ClkPara1=0x006d8157`、接口类型 | DISP/VO 硬编码显示时序（1080p60 fallback；实际时序运行时从 EDID） |
| `source/boot/product/driver/graphic/gfx/hi_gfx_layer.c` | `BOOT_GFX_DisplayLogoWithLayer` 的 `G0_ADDR`/`G0_STRIDE`/`G0_IRESO` 写入序列 | GFX 图层配置（地址/格式/stride/enabled） |
| `source/boot/product/driver/hdmi/hdmi_1_4/{de,hdmitx,phy,infofrm}.c` | HDMI TX / PHY 寄存器初始化、`HDMI_Display()`、`TX_PHY_WriteRegister` | HDMI 输出点亮 + AVI InfoFrame |
| `source/msp/drv/{vo,hifb}/` + `hi_reg_vdp.h` | 寄存器结构体定义、偏移交叉验证 | **偏移未定**：docs/023 §4.2 的 `G0_ADDR=+0x494` 系列与近期全量反汇编的 `G0_CTRL=+0x6000 / G0_ADDR=+0x6010 / STRIDE=+0x601c / IRESO=+0x6020`（`layer*0x800`）系列冲突，以研究员本轮 FINDINGS 为准 |

寄存器基址（docs/027 §4.2 二进制实证）：VO/VDP `0xf8cc0000`、HDMI TX `0xf8ce0000`、VDP 备用 `0xf9000000`。

> ⚠ **写驱动前必须先定死寄存器偏移，当前不要在驱动里写死任一组值。**
> 两套偏移直接冲突：docs/023 §4.2（SDK 推导）`G0_ADDR=+0x494 / STRIDE=+0x49c / IRESO=+0x4a0`、`VO_REG_SIZE=0x1000`，
> 与上一轮反汇编（SDK `hi_reg_vdp.h` 结构体逐字段算偏移 + 两个真实内核 disasm 出现 `add #0x6000; str ... [r?, lsl #11]`）
> `G0_CTRL=+0x6000 / G0_ADDR=+0x6010 / STRIDE=+0x601c / IRESO=+0x6020`、`GFX_OFFSET=0x800`、
> `ioremap` 需 ≥`0x7000`。legacy `patches/kernel/hi3798mv100-hdmi-console.c` 目前仍用旧值、只读不写。
> 已列入研究员本轮校验点；序列与偏移未由 FINDINGS 一锤定音前，backport 驱动不得落地寄存器写入。

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
  复用已内置的绿带 boot marker 语义（证明内核起来了）。
- `configs/kernel/` 片段加 `CONFIG_HI3798MV100_VENDOR_DISPLAY=y`。

## 接线（已改）
- `.github/workflows/build-release.yml`：`display_driver` input（`simplefb` 默认 / `vendor-backport`），
  `build-kernel` job 传 `DISPLAY_DRIVER`。
- `scripts/build-kernel.sh`：`DISPLAY_DRIVER=vendor-backport` 分支应用本目录补丁、复制驱动、
  跳过 simplefb 占位注入；驱动未就绪 fail-fast。默认 `simplefb` 路径不变，CI 不破坏。

## 判据
- 编译：CI 出 `hi_kernel.bin`（6.3 + 新驱动），`grep CONFIG_HI3798MV100_VENDOR_DISPLAY=y`。
- 真机：绿带 / 启动文字 / IP（docs/052 §5）。内核是否起来是前置：静态反汇编不能判定，必须真机信号。
