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
#include <linux/console.h>
#include <linux/font.h>
#include <linux/spinlock.h>

/*
 * SELF-DRAWN FRAMEBUFFER CONSOLE ("hi3798fb")
 *
 * On this serial-less board none of the usual log channels survive a bad
 * flash: pstore/ramoops is lost on power cut, ttyAMA0 has no UART wired,
 * fbcon needs the whole VT/simplefb bind chain which may never come up, and
 * there is no SSH until userspace+network are alive. But the green boot
 * marker proved three things on real hardware: the hiboot framebuffer is
 * writable cached DDR, VO keeps scanning it, and the kernel reaches this
 * subsys_initcall. So we register a tiny console that draws printk text
 * straight into that framebuffer with the built-in VGA 8x16 font, and let
 * CON_PRINTBUFFER replay the entire boot log at registration time. One flash
 * then shows, on HDMI, exactly where the kernel stops (rootwait, an initcall
 * panic, a deferred MMC probe, etc.) - no serial, no network, no fbcon.
 *
 * This is IN ADDITION TO, not instead of, the simple-framebuffer/TTY path:
 * the green L0 band and the simplefb pdev are untouched. If fbcon later
 * binds it takes over the same memory; our writes simply stop mattering.
 * console->write can run in ANY context (panic, NMI, with arbitrary locks
 * held), so it must never sleep: it uses a persistent cpu mapping made in
 * init, a raw spin_trylock (drop a line rather than deadlock), and only
 * writes pixels. No allocation, no printk recursion, no ioremap in write.
 */
#define CON_FG          0xffffffffu	/* a8r8g8b8 white text */
#define CON_BG          0xff000000u	/* a8r8g8b8 black */
#define CON_GLYPH_W     8
#define CON_GLYPH_H     16
#define CON_FONT_NAME   "VGA8x16"

#define VO_REG_BASE    0xf8cc0000UL
#define VO_REG_SIZE    0xfff0
#define VO_G0_ADDR     0x6010
#define VO_G0_NADDR    0x6018
#define VO_G0_STRIDE   0x601c
#define VO_G0_IRESO    0x6020

/* SDK drv_hifb_hal.c:39 "STRIDE_ALIGN 16"; :616 reads the G0_STRIDE
 * register as (surface_stride * STRIDE_ALIGN) bytes.  The register stores
 * the scanline pitch in units of 16 bytes, NOT bytes.  Using the raw value
 * as a byte stride (an earlier bug) shears the whole text area ~45deg. */
#define STRIDE_ALIGN   16

/* A plausible 32bpp byte-pitch: 320..4096 px/line, 4-byte aligned.
 * Used to tell the two G0_STRIDE encodings apart without guessing width. */
#define VD_PITCH_SANE(p)  ((p) >= 320u * 4 && (p) <= 4096u * 4 && !((p) & 3))

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

/* Self-drawn boot console: draws printk straight to the hiboot framebuffer
 * so the boot log is visible on HDMI without serial/network/fbcon. Default
 * on; set ...boot_console=0 on the cmdline to disable if it ever interferes
 * with a late-bound fbcon. */
static bool vd_boot_console = true;
module_param_named(boot_console, vd_boot_console, bool, 0444);
MODULE_PARM_DESC(boot_console,
	"Draw the kernel boot log on the HDMI framebuffer (default on).");

/* Optional cmdline override if the VO G0_STRIDE decode is ever wrong on a
 * given hiboot build: hi3798mv100_vendor_display.con_stride=<bytes>.
 * 0 (default) = derive the scan pitch from the hardware register. */
static u32 vd_con_force_stride;
module_param_named(con_stride, vd_con_force_stride, uint, 0444);
MODULE_PARM_DESC(con_stride,
	"Force console scanline stride in bytes (0 = derive from VO G0_STRIDE).");

static void __iomem *vo_base;
static struct platform_device *vd_simplefb_pdev;

/* Self-drawn console state. vd_con_fb is a PERSISTENT mapping of the
 * hiboot framebuffer, made once in init: console->write must not sleep.
 * Kept MEMREMAP_WB on purpose -- see the note in vd_con_setup(). */
static u32 *vd_con_fb;         /* cpu address of pixel (0,0) */
static u32  vd_con_stride;     /* bytes per scanline */
static u32  vd_con_w, vd_con_h;/* visible pixels */
static u32  vd_con_cols, vd_con_rows;   /* text grid */
static u32  vd_con_x, vd_con_y;/* current cursor (glyph units) */
static const struct font_desc *vd_con_font;
static DEFINE_RAW_SPINLOCK(vd_con_lock);

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

/*
 * Paint the L0 green band. This MUST stay independent of the console: if the
 * font lookup or the persistent mapping ever fails, the green band (already
 * proven on real HW) must still appear. Prefer the persistent mapping when
 * available, otherwise fall back to a one-shot WB mapping.
 */
static void vd_paint_boot_marker(phys_addr_t addr, u32 stride)
{
	size_t words = (size_t)(stride / 4) * BOOT_MARK_LINES;
	u32 *w = vd_con_fb;
	bool temp = false;
	size_t i;

	if (!w) {
		void *p = memremap(addr, (size_t)stride * BOOT_MARK_LINES,
				   MEMREMAP_WB);
		if (!p) {
			pr_warn("hi3798-vd: cannot map framebuffer for boot marker\n");
			return;
		}
		w = (u32 *)p;
		temp = true;
	}
	for (i = 0; i < words; i++)
		w[i] = BOOT_MARK_COLOR;
	if (temp)
		memunmap(w);
}

/* ----- self-drawn framebuffer console ------------------------------------ */

/* Clear one text row (in the region below the green band) to background. */
static void vd_con_clear_row(u32 row)
{
	u32 y0 = BOOT_MARK_LINES + row * CON_GLYPH_H;
	u32 r, b;
	u32 *line;

	for (r = 0; r < CON_GLYPH_H; r++) {
		line = vd_con_fb + (size_t)(y0 + r) * (vd_con_stride / 4);
		for (b = 0; b < vd_con_w; b++)
			line[b] = CON_BG;
	}
}

/* Scroll the text region up by one row; keep the green band intact. */
static void vd_con_scroll(void)
{
	u32 *base = vd_con_fb + (size_t)BOOT_MARK_LINES * (vd_con_stride / 4);
	size_t row_words = (size_t)CON_GLYPH_H * (vd_con_stride / 4);
	size_t move_words = row_words * (vd_con_rows - 1);

	memmove(base, base + row_words, move_words * sizeof(u32));
	vd_con_clear_row(vd_con_rows - 1);
}

static void vd_con_newline(void)
{
	vd_con_x = 0;
	if (vd_con_y + 1 < vd_con_rows)
		vd_con_y++;
	else
		vd_con_scroll();
}

/* Draw one glyph at text cell (col,row). VGA8x16: font->data[c*16 + r],
 * bit7 = leftmost pixel. */
static void vd_con_putc_at(u32 col, u32 row, char c)
{
	const struct font_desc *f = vd_con_font;
	const u8 *g = (const u8 *)f->data + (u8)c * CON_GLYPH_H;
	u32 x0 = col * CON_GLYPH_W;
	u32 y0 = BOOT_MARK_LINES + row * CON_GLYPH_H;
	u32 r, b;
	u32 *line;

	for (r = 0; r < CON_GLYPH_H; r++) {
		u8 bits = g[r];
		line = vd_con_fb + (size_t)(y0 + r) * (vd_con_stride / 4) + x0;
		for (b = 0; b < CON_GLYPH_W; b++)
			line[b] = (bits & (0x80u >> b)) ? CON_FG : CON_BG;
	}
}

/*
 * console->write: may be called from ANY context (panic, NMI, arbitrary
 * locks held, CPU offline). Never sleep, never allocate, never re-enter
 * printk. Use a raw trylock and drop the line if contended - far better to
 * lose one log line than to deadlock the very kernel we are debugging.
 */
static void vd_con_write(struct console *co, const char *s, unsigned int count)
{
	unsigned long flags;
	unsigned int i;

	if (!vd_con_fb || !vd_con_font || !vd_con_rows || !vd_con_cols)
		return;
	if (!raw_spin_trylock_irqsave(&vd_con_lock, flags))
		return;

	for (i = 0; i < count; i++) {
		char c = s[i];

		if (c == '\n') {
			vd_con_newline();
			continue;
		}
		if (c == '\r') {
			vd_con_x = 0;
			continue;
		}
		if (c == '\t') {
			vd_con_x = (vd_con_x + 8) & ~7u;
			if (vd_con_x >= vd_con_cols)
				vd_con_newline();
			continue;
		}
		if ((unsigned char)c < 32 || (unsigned char)c > 126)
			c = '?';
		vd_con_putc_at(vd_con_x, vd_con_y, c);
		if (++vd_con_x >= vd_con_cols)
			vd_con_newline();
	}
	raw_spin_unlock_irqrestore(&vd_con_lock, flags);
}

static struct console vd_console = {
	.name	= "hi3798fb",
	.write	= vd_con_write,
	.flags	= CON_PRINTBUFFER | CON_ENABLED | CON_ANYTIME,
	.index	= 0,
};

/*
 * Establish a persistent mapping of the hiboot framebuffer and
 * register the self-drawn console. CON_PRINTBUFFER makes the kernel replay
 * the entire boot log at registration time; every later printk is drawn as
 * it happens. Fails harmlessly (green band / simplefb path unaffected).
 */
static void vd_con_setup(phys_addr_t fb_phys, u32 width, u32 height, u32 stride)
{
	const struct font_desc *f = find_font(CON_FONT_NAME);
	size_t map_bytes = (size_t)stride * height;
	size_t max_bytes;
	void *cpu;

	if (!vd_boot_console)
		return;
	if (!f || f->width != CON_GLYPH_W || f->height != CON_GLYPH_H ||
	    f->charcount < 256) {
		pr_warn("hi3798-vd: font %s unavailable, skip boot console\n",
			CON_FONT_NAME);
		return;
	}
	/* Clamp the mapping (and later the text grid) to the DDR that actually
	 * exists above fb_phys, so a bogus ireso can never make us write past
	 * the end of RAM and oops the very kernel we are trying to debug. */
	max_bytes = (fb_phys < DDR_END) ? (size_t)(DDR_END - fb_phys) : 0;
	if (max_bytes < (size_t)stride * (BOOT_MARK_LINES + CON_GLYPH_H)) {
		pr_warn("hi3798-vd: framebuffer too close to DDR top, skip boot console\n");
		return;
	}
	if (map_bytes > max_bytes) {
		map_bytes = max_bytes;
		height = map_bytes / stride;
	}
	/* MUST use MEMREMAP_WB, not WC/WT: this framebuffer sits inside the
	 * kernel's System RAM (mem=1G, no reserved-memory/no-map region), so
	 * region_intersects() reports REGION_INTERSECTS and memremap() refuses
	 * every non-WB flag with WARN_ONCE + NULL (kernel/iomem.c:106). Switching
	 * to WC here would silently kill the whole console AND the green L0 band.
	 * The real-HW "noise eating the picture" is a separate issue: the hiboot
	 * logo buffer is not reserved from the kernel's page allocator, so pages
	 * get recycled under it over time. That needs a DTB reserved-memory fix,
	 * not a mapping-type change (see docs/053). */
	cpu = memremap(fb_phys, map_bytes, MEMREMAP_WB);
	if (!cpu) {
		pr_warn("hi3798-vd: cannot persist-map framebuffer, skip boot console\n");
		return;
	}

	vd_con_fb = (u32 *)cpu;
	vd_con_stride = stride;
	/* Visible pixels-per-line derived from the REAL scan pitch, not a
	 * guessed width, so clear_row/putc_at never cross a hardware row. */
	vd_con_w = stride / 4;
	vd_con_h = height;
	vd_con_font = f;
	vd_con_cols = vd_con_w / CON_GLYPH_W;
	if (height > BOOT_MARK_LINES)
		vd_con_rows = (height - BOOT_MARK_LINES) / CON_GLYPH_H;
	else
		vd_con_rows = 0;
	vd_con_x = 0;
	vd_con_y = 0;

	if (!vd_con_rows) {
		pr_warn("hi3798-vd: no text rows below green band, skip boot console\n");
		return;
	}

	register_console(&vd_console);
	pr_info("hi3798-vd: boot console 'hi3798fb' enabled, %ux%u text over "
		"%ux%u framebuffer (boot log replayed)\n",
		vd_con_cols, vd_con_rows, width, height);
}

static int __init hi3798_vendor_display_init(void)
{
	struct simplefb_platform_data pdata;
	struct resource res;
	phys_addr_t fb_phys;
	u32 addr, stride_raw, stride, ireso;
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

	/* Layer 0 registers as programmed by hiboot (FINDINGS.md §D offsets).
	 * G0_STRIDE holds surface_stride in units of STRIDE_ALIGN(16) bytes:
	 * SDK drv_hifb_hal.c:39 "STRIDE_ALIGN 16", :616 "GetLayerStride =
	 * surface_stride * STRIDE_ALIGN". VO scans stride_raw*16 bytes per
	 * line. Our framebuffer writes MUST use that exact pitch, otherwise
	 * every text row is sheared relative to the previous one -- the
	 * "45-degree tilted picture" seen on real HW. The old code used the
	 * raw register value as a byte pitch (16x too small) and then guessed
	 * width*4 from ireso; both are wrong. */
	addr       = vd_read_vo(VO_G0_ADDR);
	stride_raw = vd_read_vo(VO_G0_STRIDE) & 0xffff;
	ireso      = vd_read_vo(VO_G0_IRESO);
	pr_info("hi3798-vd: VO layer0: addr=0x%08x stride_raw=%u -> pitch=%uB "
		"ireso=0x%08x naddr=0x%08x\n",
		addr, stride_raw, stride_raw * STRIDE_ALIGN, ireso,
		vd_read_vo(VO_G0_NADDR));

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
	/* Recover the VO hardware scan pitch (BYTES per display row). SDK
	 * drv_hifb_hal.c:39/:616 encodes it as surface_stride = pitch/16, so
	 * pitch = stride_raw * 16. A few hiboot builds instead store the byte
	 * pitch verbatim; accept that value too if it is sane. NEVER derive the
	 * pitch from a guessed pixel width (the old width*4 heuristic): that is
	 * exactly what sheared the text -- our row advance (vd_con_stride/4)
	 * differed from VO's true scan advance, so each text line drifted
	 * sideways into a 45-degree tilted picture. The green boot band looked
	 * fine only because it is a single linear fill, not row-addressed. */
	{
		u32 pitch_x16 = stride_raw * STRIDE_ALIGN;

		if (vd_con_force_stride)             /* cmdline escape hatch */
			stride = vd_con_force_stride;
		else if (VD_PITCH_SANE(pitch_x16))
			stride = pitch_x16;              /* normal: register = pitch/16 */
		else if (VD_PITCH_SANE(stride_raw))
			stride = stride_raw;             /* some builds: byte pitch */
		else
			stride = width * 4;              /* last resort, still self-consistent */
	}
	/* Width is ALWAYS derived from the chosen byte pitch so putc_at /
	 * clear_row / scroll / simplefb all agree on the row stride. */
	width = stride / 4;
	pr_info("hi3798-vd: framebuffer geometry: %ux%u pitch=%uB "
		"(%u px/line), bpp=32, raw=%u, force=%u\n",
		width, height, stride, stride / 4, stride_raw, vd_con_force_stride);
	pdata.stride = stride;
	fb_phys = (phys_addr_t)addr;

	/*
	 * Set up the persistent framebuffer mapping + self-drawn console FIRST,
	 * so the green band and the boot-log replay share one mapping and the
	 * SAME hardware-derived pitch. vd_con_setup() does the memremap;
	 * vd_paint_boot_marker() only draws.
	 */
	vd_con_setup(fb_phys, width, height, pdata.stride);

	/* Prove the kernel booted even if fbcon never binds. Green band stays
	 * at the top; the console text region below it is left untouched. */
	vd_paint_boot_marker(fb_phys, pdata.stride);
	pr_info("hi3798-vd: BOOT MARKER (green) at 0x%08llx -- kernel alive\n",
		(unsigned long long)fb_phys);

	/* Keep simplefb's geometry self-consistent with the hardware scan pitch
	 * (width*4 == stride), so a late-bound fbcon cannot disagree with our
	 * self-drawn console's row layout. */
	pdata.width = stride / 4;
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
