// SPDX-License-Identifier: GPL-2.0
/*
 * HiSilicon Hi3798MV100 HDMI console hand-off driver
 *
 * The vendor bootloader (hiboot) initialises VO / VDP / HDMI TX and leaves a
 * logo framebuffer being scanned out of layer 0. Mainline 6.x has no Hisilicon
 * VO driver, so this driver does NOT reprogram the display engine (doing so
 * resets the bootloader state and blanks the screen - the same lesson as
 * postmarketOS's "disable display clock controllers" advice). It only:
 *
 *   1. Reads the VO layer registers that hiboot left behind: the surface
 *      address, the stride and the input resolution of layer 0.
 *   2. Registers a "simple-framebuffer" platform device pointing at that
 *      memory, so the existing fbcon (console=tty0) can draw kernel messages.
 *
 * Register layout, from the HiSTB SDK:
 *   CONFIG_VDP_REG_BASEADDR = 0xf8cc0000, CONFIG_VDP_SIZE = 0xfff0
 *     source/msp/drv/hifb/inc/drv_hifb_config.h
 *   S_VDP_REGS_TYPE, source/common/drv/include/hi3798mv100/hi_reg_vdp.h
 *     Every member is one u32, so a member's offset is 4 * its index:
 *       VOCTRL   +0x0000   layer arbitration / global control
 *       G0_ADDR  +0x0494   layer 0 surface address (physical)
 *       G0_STRIDE+0x049c   layer 0 stride (16 bit)
 *       G0_IRESO +0x04a0   layer 0 input resolution, iw[11:0] ih[23:12]
 *   Cross-checked against the SDK: OPTM_VDP_GFX_SetLayerAddrEX() accesses
 *   "&pOptmVdpReg->G0_ADDR.u32 + layer * CONFIG_HIFB_GFX_OFFSET" with
 *   CONFIG_HIFB_GFX_OFFSET = 0x800 for hi3798mv100 (this SoC exposes a single
 *   GFX layer, so G0 is all we need).
 *
 * Fallback: if the layer registers do not hold a plausible address, the HDMI
 * TX bank is scanned for a DDR-sized value, like ec6108-fbprobe does in user
 * space. All register reads use get_kernel_nofault() so an unmapped page can
 * never oops the kernel.
 *
 * If no framebuffer is found the driver steps aside; the pstore console still
 * captures panic logs.
 *
 * Built-in only (bool Kconfig): this runs as a subsys_initcall before fbcon
 * picks its console, and it never unloads.
 */

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/platform_data/simplefb.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/string.h>

/* VO register block (HiSTB SDK CONFIG_VDP_REG_BASEADDR). */
#define VO_REG_BASE     0xf8cc0000UL
#define VO_REG_SIZE     0x1000
#define VO_G0_ADDR      0x0494
#define VO_G0_STRIDE    0x049c
#define VO_G0_IRESO     0x04a0

/* HDMI TX bank, only used as a fallback probe. */
#define HDMI_TX_BASE   0xf8ce0000UL
#define HDMI_TX_SIZE   0x2000

#define PAGE_SIZE_4K   0x1000

/* DDR is 1 GiB at physical 0x0 on this board. */
#define DDR_START      0x00000000UL
#define DDR_END        0x40000000UL

/* Fallback geometry (SDK 1080p60 table, matches the community kernel's
 * FBIOGET_VSCREENINFO: 1920x1080 ARGB8888, stride 7680). */
#define FB_WIDTH       1920
#define FB_HEIGHT      1080
#define FB_STRIDE      7680
#define FB_FORMAT      "a8r8g8b8"
#define FB_SIZE        0x800000       /* 8 MiB */

static void __iomem *vo_base;
static struct platform_device *hi3798_simplefb_pdev;

static bool hi3798_valid_fb_addr(u32 val)
{
	/* A framebuffer address is a 4 KiB-aligned DDR address, well inside
	 * the 1 GiB range, and large enough not to be a random register. */
	return val >= (DDR_START + 0x100000) && val < (DDR_END - FB_SIZE)
		&& (val & (PAGE_SIZE_4K - 1)) == 0;
}

/* Read one 32-bit MMIO word without ever faulting the kernel. */
static int hi3798_safe_read32(void __iomem *p, u32 *out)
{
	const u32 __force *src = (const u32 __force *)p;
	return get_kernel_nofault(*out, src);
}

static u32 hi3798_read_vo(u32 off)
{
	u32 val;

	if (get_kernel_nofault(val, (const u32 __force *)(vo_base + off)))
		return 0;
	return val;
}

/* Fallback: look for a DDR-sized value in the HDMI TX register bank.
 * The physical bank must be ioremapped first - casting a physical address
 * to a __iomem pointer would read an unmapped virtual address. */
static u32 hi3798_scan_hdmi_tx(void)
{
	void __iomem *tx;
	size_t off;
	u32 best = 0;

	tx = ioremap(HDMI_TX_BASE, HDMI_TX_SIZE);
	if (!tx)
		return 0;
	for (off = 0; off + 4 <= HDMI_TX_SIZE; off += 4) {
		u32 val;
		if (hi3798_safe_read32(tx + off, &val))
			continue;
		if (!hi3798_valid_fb_addr(val))
			continue;
		if (!best) {
			best = val;
			pr_info("hi3798-fb: HDMI TX+0x%04zx holds 0x%08x\n",
				off, val);
		}
	}
	iounmap(tx);
	return best;
}

/* Confirm the candidate really contains pixel data, not a zeroed page. */
static bool hi3798_fb_has_content(phys_addr_t addr)
{
	void __iomem *p;
	unsigned int i, nonzero = 0;
	u32 v;

	p = memremap(addr, 64, MEMREMAP_WB);
	if (!p)
		return false;
	for (i = 0; i < 64; i += 4) {
		if (hi3798_safe_read32(p + i, &v))
			break;
		nonzero += !!v;
	}
	memunmap(p);
	return nonzero > 0;
}

static int __init hi3798_hdmi_console_init(void)
{
	struct simplefb_platform_data pdata;
	struct resource res;
	phys_addr_t fb_phys;
	u32 addr, stride, ireso;
	u32 width = FB_WIDTH, height = FB_HEIGHT;
	int ret;

	vo_base = ioremap(VO_REG_BASE, VO_REG_SIZE);
	if (!vo_base) {
		pr_warn("hi3798-fb: cannot ioremap VO registers\n");
		return -ENOMEM;
	}

	/* Layer 0 registers as programmed by hiboot. */
	addr   = hi3798_read_vo(VO_G0_ADDR);
	stride = hi3798_read_vo(VO_G0_STRIDE) & 0xffff;
	ireso  = hi3798_read_vo(VO_G0_IRESO);

	pr_info("hi3798-fb: VO layer0: addr=0x%08x stride=%u ireso=0x%08x\n",
		addr, stride, ireso);

	if (hi3798_valid_fb_addr(addr)) {
		u32 w = ireso & 0xfff;
		u32 h = (ireso >> 12) & 0xfff;

		if (w >= 320 && w <= 4096 && h >= 200 && h <= 4096) {
			width = w;
			height = h;
		}
		if (stride >= width * 4 && stride <= width * 8)
			pdata.stride = stride;
		else
			pdata.stride = width * 4;
	} else {
		pr_warn("hi3798-fb: layer0 address 0x%08x not usable, "
			"scanning HDMI TX\n", addr);
		addr = hi3798_scan_hdmi_tx();
		if (!addr) {
			pr_warn("hi3798-fb: no hiboot framebuffer found; HDMI "
				"console disabled (pstore logs still available)\n");
			iounmap(vo_base);
			vo_base = NULL;
			return -ENODEV;
		}
		width = FB_WIDTH;
		height = FB_HEIGHT;
		pdata.stride = FB_STRIDE;
	}

	if (!hi3798_fb_has_content(addr)) {
		pr_warn("hi3798-fb: 0x%08x has no pixel content, skipping\n",
			addr);
		iounmap(vo_base);
		vo_base = NULL;
		return -ENODEV;
	}

	fb_phys = (phys_addr_t)addr;
	pr_info("hi3798-fb: hiboot framebuffer at 0x%08x, registering %ux%u console\n",
		addr, width, height);

	pdata.width = width;
	pdata.height = height;
	pdata.format = FB_FORMAT;

	memset(&res, 0, sizeof(res));
	res.start = fb_phys;
	res.end = fb_phys + FB_SIZE - 1;
	res.flags = IORESOURCE_MEM;
	res.name = "hiboot framebuffer";

	hi3798_simplefb_pdev = platform_device_alloc("simple-framebuffer", 0);
	if (!hi3798_simplefb_pdev) {
		ret = -ENOMEM;
		goto out_unmap;
	}
	ret = platform_device_add_resources(hi3798_simplefb_pdev, &res, 1);
	if (ret)
		goto out_put;
	ret = platform_device_add_data(hi3798_simplefb_pdev, &pdata,
				       sizeof(pdata));
	if (ret)
		goto out_put;
	ret = platform_device_add(hi3798_simplefb_pdev);
	if (ret) {
		pr_err("hi3798-fb: cannot register simple-framebuffer: %d\n",
		       ret);
		goto out_put;
	}

	iounmap(vo_base);
	vo_base = NULL;
	return 0;

out_put:
	platform_device_put(hi3798_simplefb_pdev);
	hi3798_simplefb_pdev = NULL;
out_unmap:
	if (vo_base) {
		iounmap(vo_base);
		vo_base = NULL;
	}
	return ret;
}
subsys_initcall(hi3798_hdmi_console_init);
