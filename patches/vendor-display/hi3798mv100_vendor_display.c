// SPDX-License-Identifier: GPL-2.0
/*
 * Hi3798MV100 vendor VO/HDMI display-stack backport — SKELETON
 * (mainline 6.3 kernel + HiSilicon private register knowledge)
 *
 * See docs/052, patches/vendor-display/PORTING.md and the reusable reverse
 * engineering output in research/full-disasm/.
 *
 * HONEST SCOPE — read this before trusting the driver:
 *  - This is a compile-and-boot SKELETON, not a complete display stack.
 *  - Hiboot already initialises VO/VDP/HDMI TX/PHY and leaves a logo
 *    framebuffer being scanned out of GFX layer 0. Reprogramming the display
 *    engine (CRG reset / HDMI PHY re-init / TX re-init) after hiboot has lit
 *    HDMI BLANKS THE SCREEN — the same lesson as the legacy
 *    hi3798mv100-hdmi-console.c and the postmarketOS porting guidance. So
 *    this driver does NOT, by default, touch any VO/HDMI/CRG output register.
 *  - What it DOES do: read the vendor VO layer-0 registers that hiboot left
 *    (surface address / stride / input resolution), register a
 *    "simple-framebuffer" platform device pointing at that DDR buffer so
 *    fbcon (console=tty0, fbcon=map:0) can show kernel boot logs on HDMI,
 *    and paint a green L0 boot marker proving the kernel reached here.
 *  - The deterministic register sequences recovered from the stock 3.10 /
 *    4.4 kernels (HDMI PHY 7 writes incl. DRV=0x04, CRG reset) are compiled
 *    in as a DATA TABLE (vd_hw_init[]) traced to
 *    research/full-disasm/reg_init_sequence.{md,tsv}. They are NOT executed
 *    unless the boot parameter run_hw_init=1 is given. A full
 *    HI_DRV_HDMI_Init -> DISP_Init -> Open -> Reset -> WakeUp -> G0 -> AVI
 *    chain needs runtime EDID / HPD / timing / sink info that is still
 *    [未知] (see UNKNOWNS.md) and is intentionally NOT faked here. Turning
 *    the runner on without that data can blank the screen; it exists only
 *    for later, real-HW-confirmed work.
 *
 * Register layout is the [观察]-settled truth from FINDINGS.md §D:
 *   VO base 0xf8cc0000, window 0xfff0 (SDK CONFIG_VDP_SIZE).
 *   The FULL S_VDP_REGS_TYPE keeps every Reserved_NN[] gap, so GFX layer 0
 *   is in the +0x6000 segment: G0_CTRL +0x6000 / G0_ADDR +0x6010 /
 *   G0_STRIDE +0x601c / G0_IRESO +0x6020. The old +0x494 view was a
 *   "605 u32 compact struct" miscalculation (+0x494 is GP1_PARARD).
 *   addr(layer N) = VO + 0x6010 + (N << 11); we only read layer 0.
 *   The live MMIO value at 0xf8cc6010 is still [未知] (UNKNOWNS §3): all
 *   reads use get_kernel_nofault and fall back safely; none writes hardware.
 *
 * Register bases ([观察], reg_init_sequence.md §0):
 *   VO/VDP 0xf8cc0000 | HDMI TX 0xf8ce0000 | PHY 0xf8ce1800 | CRG 0xf8a22000
 *
 * Built-in only (bool Kconfig): subsys_initcall, never unloads.
 */

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/platform_device.h>
#include <linux/platform_data/simplefb.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/slab.h>

#define VO_REG_BASE    0xf8cc0000UL
#define VO_REG_SIZE    0xfff0
#define VO_G0_ADDR     0x6010
#define VO_G0_STRIDE   0x601c
#define VO_G0_IRESO    0x6020

#define PHY_BASE       0xf8ce1800UL
#define PHY_SIZE       0x100
#define CRG_BASE       0xf8a22000UL
#define CRG_SIZE       0x200

#define DDR_START      0x00000000UL
#define DDR_END        0x40000000UL
#define FB_ADDR_MARGIN 0x800000

#define BOOT_MARK_LINES 240
#define BOOT_MARK_COLOR 0xff00ff00u	/* a8r8g8b8 opaque green */

#define FB_WIDTH   1920
#define FB_HEIGHT  1080
#define FB_FORMAT  "a8r8g8b8"
#define FB_SIZE    0x1000000      /* 16 MiB: covers two 1080p frames */

/*
 * Deterministic replay order from reg_init_sequence.md §1/§2 (STATIC writes
 * only; RMW / DDC-speed / EDID / InfoFrame items are [推断]/[未知] and are
 * deliberately excluded):
 *   CRG reset assert -> phy reset -> Delay -> phy de-reset -> Delay ->
 *   HDMI PHY 7 writes (SI_TX_PHY_INIT) -> Delay -> CRG de-reset -> Delay.
 * Sequence A reg5 (DRV) = 0x04 in BOTH stock kernels (SDK phy.c mv100 source
 * says 0x01 — source/binary drift; keep the binary value). PHY PWD
 * (power-up) write is deliberately LAST among the PHY writes.
 *
 * DATA ONLY by default: see vd_replay_sequences() and the header caveat.
 */
struct vd_step {
	u32 phys;      /* absolute physical register address */
	u32 val;       /* value to write */
	u32 delay_ms;  /* delay AFTER this write */
};

static const struct vd_step vd_hw_init[] = {
	{ 0xf8a2210c, 0x23f, 0 },  /* CRG +0x10c reset assert */
	{ 0xf8a22110, 0x10,  1 },  /* CRG +0x110 phy reset, DelayMS(1) */
	{ 0xf8a22110, 0x01,  1 },  /* CRG +0x110 phy de-reset, DelayMS(1) */
	{ 0xf8ce1800, 0x00, 0 },   /* PHY OE   (reg 0) */
	{ 0xf8ce1808, 0x02, 0 },   /* PHY AUD  (reg 2) */
	{ 0xf8ce180c, 0x02, 0 },   /* PHY PLL1 (reg 3) */
	{ 0xf8ce1810, 0x09, 0 },   /* PHY PLL2 (reg 4) */
	{ 0xf8ce1814, 0x04, 0 },   /* PHY DRV  (reg 5): binary 0x04, SDK 0x01 */
	{ 0xf8ce1818, 0x00, 0 },   /* PHY CLK  (reg 6) */
	{ 0xf8ce1804, 0x01, 1 },   /* PHY PWD  (reg 1): power-up last, DelayMS(1) */
	{ 0xf8a2210c, 0x3f, 10 },  /* CRG +0x10c de-reset, DelayMS(10) */
};

static bool vd_run_hw_init;
module_param_named(run_hw_init, vd_run_hw_init, bool, 0444);
MODULE_PARM_DESC(run_hw_init,
	"Replay the recovered PHY/CRG register sequences (DANGER: blanks the "
	"hiboot-lit HDMI output; needs real-HW EDID/timing data first). Default 0. "
	"Set via hi3798mv100_vendor_display.run_hw_init=1 on the kernel cmdline.");

static void __iomem *vo_base;
static struct platform_device *vd_simplefb_pdev;

static bool vd_valid_fb_addr(u32 val)
{
	return val >= (DDR_START + 0x100000) && val < (DDR_END - FB_ADDR_MARGIN)
		&& (val & 0xfff) == 0;
}

/* Read one 32-bit MMIO word without ever faulting the kernel. */
static u32 vd_read_vo(u32 off)
{
	u32 val;

	if (get_kernel_nofault(val, (const u32 __force *)(vo_base + off)))
		return 0;
	return val;
}

/*
 * Optional, DEFAULT-OFF: replay the deterministic sequences so the recovered
 * register knowledge is compiled and runnable once real hardware confirms the
 * display is NOT already lit and EDID/timing are available. This does NOT
 * implement HI_DRV_HDMI_Init (still [未知]). Never runs in the shipped build.
 */
static void vd_replay_sequences(void)
{
	void __iomem *phy = ioremap(PHY_BASE, PHY_SIZE);
	void __iomem *crg = ioremap(CRG_BASE, CRG_SIZE);
	int i;

	if (!phy || !crg) {
		pr_warn("hi3798-vd: cannot ioremap PHY/CRG, sequences skipped\n");
		goto out;
	}
	for (i = 0; i < ARRAY_SIZE(vd_hw_init); i++) {
		const struct vd_step *s = &vd_hw_init[i];
		void __iomem *reg;

		if (s->phys >= CRG_BASE && s->phys < CRG_BASE + CRG_SIZE)
			reg = crg + (s->phys - CRG_BASE);
		else if (s->phys >= PHY_BASE && s->phys < PHY_BASE + PHY_SIZE)
			reg = phy + (s->phys - PHY_BASE);
		else
			continue;
		writel(s->val, reg);
		if (s->delay_ms)
			mdelay(s->delay_ms);
	}
	pr_warn("hi3798-vd: replayed PHY/CRG sequences (INCOMPLETE stack, "
		"screen may be blank)\n");
out:
	if (phy)
		iounmap(phy);
	if (crg)
		iounmap(crg);
}

static void vd_paint_boot_marker(phys_addr_t addr, u32 stride)
{
	size_t len = (size_t)stride * BOOT_MARK_LINES;
	void *p = memremap(addr, len, MEMREMAP_WB);
	u32 *w;
	size_t i, n;

	if (!p) {
		pr_warn("hi3798-vd: cannot map framebuffer for boot marker\n");
		return;
	}
	w = p;
	n = len / sizeof(u32);
	for (i = 0; i < n; i++)
		w[i] = BOOT_MARK_COLOR;
	memunmap(p);
	pr_info("hi3798-vd: BOOT MARKER (green) at 0x%08llx -- kernel alive\n",
		(unsigned long long)addr);
}

static int __init hi3798_vendor_display_init(void)
{
	struct simplefb_platform_data pdata;
	struct resource res;
	phys_addr_t fb_phys;
	u32 addr, stride, ireso;
	u32 width = FB_WIDTH, height = FB_HEIGHT;
	int ret;

	/* Compile-time + boot-time proof the recovered table is in the image. */
	pr_info("hi3798-vd: vendor display skeleton; %zu deterministic writes "
		"compiled in (data only, run_hw_init=%d)\n",
		ARRAY_SIZE(vd_hw_init), vd_run_hw_init);

	if (vd_run_hw_init)
		vd_replay_sequences();

	vo_base = ioremap(VO_REG_BASE, VO_REG_SIZE);
	if (!vo_base) {
		pr_warn("hi3798-vd: cannot ioremap VO registers\n");
		return -ENOMEM;
	}

	/* Layer 0 registers as programmed by hiboot (FINDINGS.md §D offsets). */
	addr   = vd_read_vo(VO_G0_ADDR);
	stride = vd_read_vo(VO_G0_STRIDE) & 0xffff;
	ireso  = vd_read_vo(VO_G0_IRESO);
	pr_info("hi3798-vd: VO layer0: addr=0x%08x stride=%u ireso=0x%08x\n",
		addr, stride, ireso);

	if (!vd_valid_fb_addr(addr)) {
		/* No hard-coded fb_base: the hand-off address is [未知] across
		 * boots. Unlike the legacy driver we do NOT scan random register
		 * banks; step aside and let pstore/fbcon tell the story. */
		pr_warn("hi3798-vd: layer0 addr 0x%08x not usable; no framebuffer "
			"registered (pstore logs still available)\n", addr);
		iounmap(vo_base);
		vo_base = NULL;
		return -ENODEV;
	}

	{
		u32 w = ireso & 0xfff;
		u32 h = (ireso >> 12) & 0xfff;

		if (w >= 320 && w <= 4096 && h >= 200 && h <= 4096) {
			width = w;
			height = h;
		}
	}
	pdata.stride = (stride >= width * 4 && stride <= width * 8)
			? stride : width * 4;
	fb_phys = (phys_addr_t)addr;

	/* Prove the kernel booted even if fbcon never binds. */
	vd_paint_boot_marker(fb_phys, pdata.stride);

	pdata.width = width;
	pdata.height = height;
	pdata.format = FB_FORMAT;

	memset(&res, 0, sizeof(res));
	res.start = fb_phys;
	res.end = fb_phys + FB_SIZE - 1;
	if (res.end > DDR_END - 1)
		res.end = DDR_END - 1;
	res.flags = IORESOURCE_MEM;
	res.name = "vendor hiboot framebuffer";

	vd_simplefb_pdev = platform_device_alloc("simple-framebuffer", 0);
	if (!vd_simplefb_pdev) {
		ret = -ENOMEM;
		goto out_unmap;
	}
	ret = platform_device_add_resources(vd_simplefb_pdev, &res, 1);
	if (ret)
		goto out_put;
	ret = platform_device_add_data(vd_simplefb_pdev, &pdata, sizeof(pdata));
	if (ret)
		goto out_put;
	ret = platform_device_add(vd_simplefb_pdev);
	if (ret) {
		pr_err("hi3798-vd: cannot register simple-framebuffer: %d\n", ret);
		goto out_put;
	}
	pr_info("hi3798-vd: registered %ux%u framebuffer at 0x%08llx "
		"for fbcon/TTY\n", width, height, (unsigned long long)fb_phys);

	iounmap(vo_base);
	vo_base = NULL;
	return 0;

out_put:
	platform_device_put(vd_simplefb_pdev);
	vd_simplefb_pdev = NULL;
out_unmap:
	if (vo_base) {
		iounmap(vo_base);
		vo_base = NULL;
	}
	return ret;
}
subsys_initcall(hi3798_vendor_display_init);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hi3798MV100 vendor VO/HDMI framebuffer backport skeleton");
