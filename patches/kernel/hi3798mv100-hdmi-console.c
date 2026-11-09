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
 * Register layout, from the HiSTB SDK full struct (research/full-disasm/
 * FINDINGS.md §D, [观察] 三份真内核反汇编 + SDK S_VDP_REGS_TYPE 双 oracle):
 *   CONFIG_VDP_REG_BASEADDR = 0xf8cc0000, CONFIG_VDP_SIZE = 0xfff0
 *     source/msp/drv/hifb/inc/drv_hifb_config.h
 *   The FULL S_VDP_REGS_TYPE keeps every Reserved_NN[] gap. GFX layer 0 lives
 *   in the +0x6000 segment (NOT the compact +0x494 view -- that was a
 *   "605 u32 / 0x974 window" miscalculation; at +0x494 the full struct is
 *   GP1_PARARD, not G0_ADDR):
 *       G0_CTRL  +0x6000   layer enable / format
 *       G0_ADDR  +0x6010   layer 0 surface address (physical)
 *       G0_STRIDE+0x601c   layer 0 stride (16 bit)
 *       G0_IRESO +0x6020   layer 0 input resolution, iw[11:0] ih[23:12]
 *   addr(layer N) = 0xf8cc0000 + 0x6010 + (N<<11), CONFIG_HIFB_GFX_OFFSET
 *   = 0x800 (drv_hifb_config.h:67 mv100). We only read layer 0 (N=0).
 *   NOTE: the offsets are settled [观察], but "which register window VO is
 *   currently scanning / the live MMIO value" is still [未知] (UNKNOWNS §3,
 *   needs a real-HW read at 0xf8cc6010). This driver only reads via
 *   get_kernel_nofault and falls back safely; it never writes VO/HDMI regs.
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

/* VO register block (HiSTB SDK CONFIG_VDP_REG_BASEADDR / CONFIG_VDP_SIZE).
 * Window 0xfff0 covers the full GFX layer segment (G0 @ +0x6010..0x6020,
 * layer5 up to 0x8820). The old 0x1000 window could not even reach +0x6010. */
#define VO_REG_BASE     0xf8cc0000UL
#define VO_REG_SIZE     0xfff0
#define VO_G0_ADDR      0x6010
#define VO_G0_STRIDE    0x601c
#define VO_G0_IRESO     0x6020

/* HDMI TX bank, only used as a fallback probe. */
#define HDMI_TX_BASE   0xf8ce0000UL
#define HDMI_TX_SIZE   0x2000

#define PAGE_SIZE_4K   0x1000

/* DDR is 1 GiB at physical 0x0 on this board. */
#define DDR_START      0x00000000UL
#define DDR_END        0x40000000UL

/* Diagnostic boot marker. hiboot leaves the p5 logo being scanned out of this
 * very framebuffer, so the VO/HDMI pipeline is already proven working. Painting
 * that buffer the moment this driver runs gives an unmistakable "the Linux
 * kernel booted and reached subsys_initcall" signal that needs no fbcon, no
 * console=tty0, no network, no rootfs and no serial. If simplefb/fbcon fails
 * to bind, the colour simply stays on screen - which is exactly the case we
 * are debugging. Only the top BOOT_MARK_LINES lines are touched: obvious enough
 * to see, small enough to stay safe if a discovered address is ever wrong. */
#define BOOT_MARK_LINES 240
#define BOOT_MARK_COLOR 0xff00ff00u	/* a8r8g8b8 opaque green */

/* Fallback geometry (SDK 1080p60 table, matches the community kernel's
 * FBIOGET_VSCREENINFO: 1920x1080 ARGB8888, stride 7680). */
#define FB_WIDTH       1920
#define FB_HEIGHT      1080
#define FB_STRIDE      7680
#define FB_FORMAT      "a8r8g8b8"

/* docs/040 measured the community fb0 at 1920x1080 ARGB8888 with TWO frames
 * (smem_len = 16,588,800 B = 0xFD0000), i.e. the VO scans a double-buffered
 * region. simplefb/fbcon only ever draws ONE frame (pdata.height = 1080), so
 * its geometry stays single-frame; but the IORESOURCE_MEM we register must
 * span both frames, otherwise the kernel can hand the second frame to an
 * unrelated allocation while VO is still scanning it. */
#define FB_SIZE        0x1000000      /* 16 MiB: covers two 1080p frames */
#define FB_ADDR_MARGIN 0x800000      /* one frame, for address sanity only */

static void __iomem *vo_base;
static struct platform_device *hi3798_simplefb_pdev;

static bool hi3798_valid_fb_addr(u32 val)
{
	/* A framebuffer address is a 4 KiB-aligned DDR address, well inside
	 * the 1 GiB range, and large enough not to be a random register.
	 * Use FB_ADDR_MARGIN (one frame), NOT FB_SIZE (two frames): the latter
	 * would push the upper bound down to 0x3f000000 and wrongly reject the
	 * real scan-out buffer at 0x3f6ce000 measured on the community system
	 * (docs/041 reserve-mem evidence). */
	return val >= (DDR_START + 0x100000) && val < (DDR_END - FB_ADDR_MARGIN)
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

/* Write a solid green band over the top of the hiboot framebuffer. The
 * framebuffer is ordinary DDR that the VO scanner reads continuously, so a
 * cached WB mapping is enough: the 2 MiB of stores evict their own dirty
 * lines and reach DRAM within milliseconds, with no cache-alias conflict
 * from a second ioremap of the same physical range. */
static void hi3798_paint_boot_marker(phys_addr_t addr, u32 stride)
{
	size_t len = (size_t)stride * BOOT_MARK_LINES;
	void *p;
	u32 *w;
	size_t i, n;

	p = memremap(addr, len, MEMREMAP_WB);
	if (!p) {
		pr_warn("hi3798-fb: cannot map framebuffer for boot marker\n");
		return;
	}
	w = p;
	for (i = 0, n = len / sizeof(u32); i < n; i++)
		w[i] = BOOT_MARK_COLOR;
	memunmap(p);
	pr_info("hi3798-fb: BOOT MARKER painted (green, %zu bytes) at 0x%08llx"
		" -- kernel is alive\n", len, (unsigned long long)addr);
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

	/* Prove the kernel booted even if fbcon never binds: if simplefb/fbcon
	 * fails, this green band simply stays on screen; if it succeeds, the
	 * console text overwrites it, which is an even better outcome. */
	hi3798_paint_boot_marker(fb_phys, pdata.stride);

	pdata.width = width;
	pdata.height = height;
	pdata.format = FB_FORMAT;

	memset(&res, 0, sizeof(res));
	res.start = fb_phys;
	res.end = fb_phys + FB_SIZE - 1;
	/* FB_SIZE now spans two frames. If hiboot put the scan-out buffer near
	 * the top of the 1 GiB DDR (the community reserve-mem table in docs/041
	 * lists buffers up at 0x3f6ce000), the two-frame span would run past
	 * DDR_END. Clamp the reservation so we never register an out-of-range
	 * IORESOURCE_MEM; one frame is still enough for simplefb to come up. */
	if (res.end > DDR_END - 1) {
		pr_warn("hi3798-fb: 0x%08x + 0x%x exceeds DDR_END, clamping reservation\n",
			addr, FB_SIZE);
		res.end = DDR_END - 1;
	}
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

	/* Report the hand-off parameters to pstore (the only log channel on this
	 * serial-less board). After a black-screen flash these lines tell us
	 * whether the driver found a usable hiboot framebuffer and what geometry
	 * fbcon was registered with -- see docs/040/041. */
	pr_info("hi3798-fb: HANDOFF phys=0x%08llx span=0x%x %ux%u stride=%u "
		"fmt=%s (double-buffer reserved, single-frame fbcon)\n",
		(unsigned long long)fb_phys, FB_SIZE, width, height,
		pdata.stride, FB_FORMAT);

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
