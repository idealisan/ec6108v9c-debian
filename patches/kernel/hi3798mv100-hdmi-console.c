// SPDX-License-Identifier: GPL-2.0
/*
 * HiSilicon Hi3798MV100 HDMI console hand-off driver
 *
 * The vendor bootloader (hiboot) initialises VO / VDP / HDMI TX and leaves a
 * logo framebuffer being scanned out. Mainline 6.x has no Hisilicon VO driver,
 * so this driver does NOT reprogram the display engine (doing so resets the
 * bootloader state and blanks the screen - the same lesson as postmarketOS's
 * "disable display clock controllers" advice). It only:
 *
 *   1. Reads the VO/VDP register banks left by hiboot and finds the physical
 *      address of the scan-out buffer (the same heuristic as ec6108-fbprobe,
 *      but in kernel space where ioremap makes the access safe).
 *   2. Registers a "simple-framebuffer" platform device pointing at that
 *      memory, so the existing fbcon (console=tty0) can draw kernel messages.
 *
 * Register bases come from the HiSTB SDK (drv_reg_proc.h), which explicitly
 * lists CHIP_TYPE_hi3798mv100:
 *   HDMI TX 0xf8ce0000 (SLV0) / 0xf8ce0400 (SLV1) / 0xf8ce0800 (CEC)
 *   HDMI PHY 0xf8ce1800
 *   VO/VDP   0xf9000000 .. 0xfa000000
 *
 * All reads use get_kernel_nofault() so an unmapped register page can never
 * oops the kernel. If no framebuffer is found the driver simply steps aside;
 * the pstore console still captures panic logs.
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

#define HDMI_TX_BASE   0xf8ce0000UL
#define HDMI_TX_SIZE   0x2000
#define VDP_BASE       0xf9000000UL
#define VDP_SIZE       0x10000        /* 64 KiB: layer registers live in the
				 * first banks; keep the scan small so an
				 * external-abort page cannot oops us */
#define PAGE_SIZE_4K   0x1000

/* DDR is 1 GiB at physical 0x0 on this board. */
#define DDR_START      0x00000000UL
#define DDR_END        0x40000000UL

/* 1920x1080 ARGB8888, one frame. Confirmed by the community kernel's
 * FBIOGET_VSCREENINFO/FSCREENINFO and by the SDK's own 1080p60 table. */
#define FB_WIDTH       1920
#define FB_HEIGHT      1080
#define FB_STRIDE      7680
#define FB_FORMAT      "a8r8g8b8"
#define FB_SIZE        0x800000       /* 8 MiB */

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

/* Scan a register bank for a value that looks like the scan-out buffer. */
static u32 hi3798_scan_bank(void __iomem *bank, size_t size, const char *name)
{
	size_t off;
	u32 best = 0;
	unsigned int hits = 0;

	for (off = 0; off + 4 <= size; off += 4) {
		u32 val;
		if (hi3798_safe_read32(bank + off, &val))
			continue;               /* unmapped page, skip */
		if (!hi3798_valid_fb_addr(val))
			continue;
		hits++;
		if (!best)
			best = val;
		pr_debug("hi3798-fb: %s+0x%04zx = 0x%08x (candidate)\n",
			 name, off, val);
	}
	pr_info("hi3798-fb: %s: %u framebuffer-like address(es), first 0x%08x\n",
		name, hits, best);
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
	void __iomem *hdmi, *vdp;
	struct simplefb_platform_data pdata;
	struct resource res;
	u32 addr = 0;
	int ret;

	hdmi = ioremap(HDMI_TX_BASE, HDMI_TX_SIZE);
	vdp = ioremap(VDP_BASE, VDP_SIZE);
	if (!hdmi || !vdp) {
		pr_warn("hi3798-fb: cannot ioremap display registers\n");
		ret = -ENOMEM;
		goto out_unmap;
	}

	/* Prefer the VDP layer registers; fall back to the HDMI TX bank. */
	addr = hi3798_scan_bank(vdp, VDP_SIZE, "VDP");
	if (!addr)
		addr = hi3798_scan_bank(hdmi, HDMI_TX_SIZE, "HDMI");

	if (!addr || !hi3798_fb_has_content(addr)) {
		pr_warn("hi3798-fb: no hiboot framebuffer found; HDMI console "
			"disabled (pstore logs still available)\n");
		ret = -ENODEV;
		goto out_unmap;
	}

	pr_info("hi3798-fb: hiboot framebuffer at 0x%08x, registering %dx%d %s console\n",
		addr, FB_WIDTH, FB_HEIGHT, FB_FORMAT);

	pdata.width = FB_WIDTH;
	pdata.height = FB_HEIGHT;
	pdata.stride = FB_STRIDE;
	pdata.format = FB_FORMAT;

	memset(&res, 0, sizeof(res));
	res.start = (phys_addr_t)addr;
	res.end = res.start + FB_SIZE - 1;
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

	iounmap(vdp);
	iounmap(hdmi);
	return 0;

out_put:
	platform_device_put(hi3798_simplefb_pdev);
	hi3798_simplefb_pdev = NULL;
out_unmap:
	if (vdp)
		iounmap(vdp);
	if (hdmi)
		iounmap(hdmi);
	return ret;
}
subsys_initcall(hi3798_hdmi_console_init);
