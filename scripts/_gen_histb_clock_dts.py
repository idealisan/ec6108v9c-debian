#!/usr/bin/env python3
"""Generate 0007 patch: add display clocks (VO/HDMI) to 6.3 CRG + VDP/HDMI DT nodes."""
import os,re,difflib
K='third_party/linux-hi3798mv100'
OUT='patches/kernel/0007-histb-display-clock-dts.patch'
parts=[]

def modified(path, transform, context_hint=None):
    full=os.path.join(K,path)
    orig=open(full).read().splitlines(True)
    new=transform(''.join(orig)).splitlines(True)
    d=list(difflib.unified_diff(orig,new,fromfile='a/'+path,tofile='b/'+path,n=3))
    parts.extend(d)

# 1) histb-clock.h: add 4 display clock IDs (92..95, free: max used 91, NR=128)
def clk_h(s):
    add=('/* HiSTB display clocks (backport, docs/055); IDs 92..95 are free (<128). */\n'
         '#define HISTB_VO_CLK\t\t\t92\n'
         '#define HISTB_VO_HD_CLK\t\t\t93\n'
         '#define HISTB_HDMI_CTRL_CLK\t\t\t94\n'
         '#define HISTB_HDMI_PHY_CLK\t\t\t95\n')
    # insert before final #endif
    idx=s.rfind('#endif')
    if idx<0: idx=len(s)
    return s[:idx]+add+s[idx:]
modified('include/dt-bindings/clock/histb-clock.h',clk_h)

# 2) crg-hi3798.c: add display clocks to hi3798mv100_gate_clks[].
#    clk_vo_hd (the pixel clock, "pix") is NOT a plain gate: it must be the
#    gthifb HD-PLL clock with determine/set_rate so clk_round_rate() can
#    return the real pixel rates the VDP mode_valid() checks against. A
#    fixed 100MHz gate makes every EDID mode fail MODE_NOCLOCK -> no modes
#    -> Xorg "no screens" -> black screen (root cause found 2026-11-17).
HD_PIX_CODE = r'''
/* ---- Hi3798MV100 HD pixel clock (backport from gthifb/histb-mainline
 * 500-02, verified working: this is the clock that drives VO_G0/HDMI TMDS).
 * PERI_CRG_PLL10/11 program the HD PLL; CRG54's vo_hd_clk_div halves it.
 * No loop-setting formula is documented, so rates are a register-pair table
 * (one entry per display format), exactly as upstream's driver does. */
#define CRG54				0xd8
#define  CRG54_VO_HD_CLK_DIV		GENMASK(19, 18)
#define  CRG54_CLK_DIV_2		0

struct hi3798_hd_pix_cfg {
	unsigned long	rate;
	u32		pll10;
	u32		pll11;
};

static const struct hi3798_hd_pix_cfg hi3798mv100_hd_pix_cfgs[] = {
	{  74250000, 0x14000000, 0x02002063, }, /* 720p50/60, 1080p24-30, 1080i */
	{ 148500000, 0x12000000, 0x02002063, }, /* 1080p50/60 */
	{ 297000000, 0x11000000, 0x02002063, }, /* 3840x2160@24/25/30 */
	{ 296703000, 0x11E6A7EF, 0x00002062, }, /* 3840x2160@23.976/29.97 */
	{  25200000, 0x24000000, 0x20050a8, }, /* 640x480@60 */
	{  39805440, 0x25000000, 0x201967a, }, /* 800x600@60 */
	{  65122560, 0x15000000, 0x201954a, }, /* 1024x768@60 */
	{  83764800, 0x13000000, 0x2019417, }, /* 1280x800@60 */
	{  85478400, 0x13000000, 0x2032859, }, /* 1360x768@60 */
	{  85770240, 0x13000000, 0x200a1ad, }, /* 1366x768@60 */
	{  88896000, 0x14000000, 0x2006163, }, /* 1440x900@60 RB */
	{  97785600, 0x14000000, 0x2006187, }, /* 1600x900@60 RB */
	{ 106755840, 0x12000000, 0x201e42b, }, /* 1440x900@60 */
	{ 107855040, 0x15000000, 0x20198c9, }, /* 1280x1024@60 */
	{ 121717440, 0x12000000, 0x20050cb, }, /* 1400x1050@60 */
	{ 146217600, 0x12000000, 0x2018493, }, /* 1680x1050@60 */
	{ 156750000, 0x12000000, 0x200309d, }, /* 2048x1152@60 */
	{ 162000000, 0x12000000, 0x2001036, }, /* 1600x1200@60 */
	{ 234000000, 0x11000000, 0x2001027, }, /* 1920x1440@60 */
	{ 241500000, 0x12000000, 0x20020a1, }, /* 2560x1440@60 RB */
	{ 268500000, 0x12000000, 0x20020b3, }, /* 2560x1600@60 RB */
};

struct hi3798_hd_pix_clock {
	struct clk_hw	hw;
	void __iomem	*pll10;
	void __iomem	*pll11;
	void __iomem	*crg54;
};
#define to_hi3798_hd_pix_clock(_hw) \
	container_of(_hw, struct hi3798_hd_pix_clock, hw)

static const struct hi3798_hd_pix_cfg *hi3798_hd_pix_cfg(unsigned long rate)
{
	const struct hi3798_hd_pix_cfg *best = &hi3798mv100_hd_pix_cfgs[0];
	unsigned long diff = ~0UL;
	int i;

	for (i = 0; i < ARRAY_SIZE(hi3798mv100_hd_pix_cfgs); i++) {
		const struct hi3798_hd_pix_cfg *cfg = &hi3798mv100_hd_pix_cfgs[i];
		unsigned long delta = rate > cfg->rate ? rate - cfg->rate :
							     cfg->rate - rate;
		if (delta < diff) {
			diff = delta;
			best = cfg;
		}
	}
	return best;
}

static unsigned long hi3798_hd_pix_recalc_rate(struct clk_hw *hw,
					       unsigned long parent_rate)
{
	struct hi3798_hd_pix_clock *clk = to_hi3798_hd_pix_clock(hw);
	u32 pll10 = readl_relaxed(clk->pll10);
	u32 pll11 = readl_relaxed(clk->pll11);
	int i;

	for (i = 0; i < ARRAY_SIZE(hi3798mv100_hd_pix_cfgs); i++) {
		const struct hi3798_hd_pix_cfg *cfg = &hi3798mv100_hd_pix_cfgs[i];
		if (cfg->pll10 == pll10 && cfg->pll11 == pll11 &&
		    FIELD_GET(CRG54_VO_HD_CLK_DIV, readl_relaxed(clk->crg54)) ==
		    CRG54_CLK_DIV_2)
			return cfg->rate;
	}
	return 0;
}

static int hi3798_hd_pix_determine_rate(struct clk_hw *hw,
					struct clk_rate_request *req)
{
	req->rate = hi3798_hd_pix_cfg(req->rate)->rate;
	return 0;
}

static int hi3798_hd_pix_set_rate(struct clk_hw *hw, unsigned long rate,
				  unsigned long parent_rate)
{
	struct hi3798_hd_pix_clock *clk = to_hi3798_hd_pix_clock(hw);
	const struct hi3798_hd_pix_cfg *cfg = hi3798_hd_pix_cfg(rate);
	u32 pll10_old = readl_relaxed(clk->pll10);
	u32 pll11_old = readl_relaxed(clk->pll11);
	u32 crg54_old = readl_relaxed(clk->crg54);
	u32 val;

	val = (crg54_old & ~CRG54_VO_HD_CLK_DIV) |
	      FIELD_PREP(CRG54_VO_HD_CLK_DIV, CRG54_CLK_DIV_2);
	writel_relaxed(cfg->pll10, clk->pll10);
	writel_relaxed(cfg->pll11, clk->pll11);
	writel_relaxed(val, clk->crg54);
	if (readl_relaxed(clk->pll10) == cfg->pll10 &&
	    readl_relaxed(clk->pll11) == cfg->pll11 &&
	    readl_relaxed(clk->crg54) == val)
		return 0;
	writel_relaxed(pll10_old, clk->pll10);
	writel_relaxed(pll11_old, clk->pll11);
	writel_relaxed(crg54_old, clk->crg54);
	return -EIO;
}

static const struct clk_ops hi3798_hd_pix_ops = {
	.recalc_rate = hi3798_hd_pix_recalc_rate,
	.determine_rate = hi3798_hd_pix_determine_rate,
	.set_rate = hi3798_hd_pix_set_rate,
};

static struct clk *hi3798_clk_register_hd_pix(struct device *dev, void __iomem *base)
{
	struct hi3798_hd_pix_clock *clk;
	static const char *const parents[] = { "clk_osc" };
	struct clk_init_data init = {
		.name = "clk_vo_hd",
		.ops = &hi3798_hd_pix_ops,
		.parent_names = parents,
		.num_parents = ARRAY_SIZE(parents),
	};

	clk = devm_kzalloc(dev, sizeof(*clk), GFP_KERNEL);
	if (!clk)
		return ERR_PTR(-ENOMEM);
	clk->hw.init = &init;
	clk->pll10 = base + 0x28;
	clk->pll11 = base + 0x2c;
	clk->crg54 = base + CRG54;
	return devm_clk_register(dev, &clk->hw);
}
/* ---- end HD pixel clock ---- */
'''

def crg(s):
    # add <linux/bitfield.h> for FIELD_GET/FIELD_PREP
    s = s.replace('#include <linux/clk-provider.h>\n',
                  '#include <linux/clk-provider.h>\n#include <linux/bitfield.h>\n', 1)
    # gate table: add 3 plain gates (vo, hdmi_ctrl, hdmi_phy) but NOT clk_vo_hd
    marker='static const struct hisi_gate_clock hi3798mv100_gate_clks[] = {'
    i=s.find(marker)
    j=s.find('\n};',i)
    add=('\n\t/* HiSTB display gates (docs/055). clk_vo_hd (pixel clock) is a\n'
         '\t * dedicated HD-PLL clock registered in hi3798mv100_clk_register. */\n'
         '\t{ HISTB_VO_CLK, "clk_vo", "clk_apb", 0, 0xd8, 0, 0, },\n'
         '\t{ HISTB_HDMI_CTRL_CLK, "clk_hdmi_ctrl", "clk_apb", 0, 0x10c, 0, 0, },\n'
         '\t{ HISTB_HDMI_PHY_CLK, "clk_hdmi_phy", "clk_apb", 0, 0x110, 0, 0, },')
    s = s[:j]+add+s[j:]
    # insert HD pixel clock code just before hi3798mv100_clk_register
    reg='static struct hisi_clock_data *hi3798mv100_clk_register('
    k=s.find(reg)
    s = s[:k]+HD_PIX_CODE+'\n'+s[k:]
    # override clk_vo_hd slot with the HD-PLL clock
    old=('static struct hisi_clock_data *hi3798mv100_clk_register(\n'
         '\t\t\t\tstruct platform_device *pdev)\n'
         '{\n'
         '\treturn hi3798_clk_register(pdev, &hi3798mv100_crg_clks);\n'
         '}')
    new=('static struct hisi_clock_data *hi3798mv100_clk_register(\n'
         '\t\t\t\tstruct platform_device *pdev)\n'
         '{\n'
         '\tstruct hisi_clock_data *data =\n'
         '\t\thi3798_clk_register(pdev, &hi3798mv100_crg_clks);\n'
         '\tstruct clk *hd_pix;\n\n'
         '\tif (IS_ERR(data))\n'
         '\t\treturn data;\n'
         '\t/* clk_vo_hd is the pixel clock ("pix"); it must round/set to the\n'
         '\t * real HD-PLL rates, not sit at the 100MHz parent rate. */\n'
         '\thd_pix = hi3798_clk_register_hd_pix(&pdev->dev, data->base);\n'
         '\tif (!IS_ERR(hd_pix))\n'
         '\t\tdata->clk_data.clks[HISTB_VO_HD_CLK] = hd_pix;\n'
         '\treturn data;\n'
         '}')
    if old not in s:
        raise SystemExit('ERROR: hi3798mv100_clk_register pattern not found')
    s = s.replace(old,new,1)
    return s
modified('drivers/clk/hisilicon/crg-hi3798.c',crg)

# 3) dtsi: add vdp + hdmi nodes (disabled) after gpu node block
def dtsi(s):
    marker='\t\tnand: nand@9810000 {'
    nodes=('\t\tvdp: display@8cc0000 {\n'
           '\t\t\tcompatible = "hisilicon,hi3798mv100-vdp";\n'
           '\t\t\treg = <0x8cc0000 0x10000>;\n'
           '\t\t\tinterrupts = <GIC_SPI 90 IRQ_TYPE_LEVEL_HIGH>;\n'
           '\t\t\tclocks = <&crg HISTB_VO_HD_CLK>, <&crg HISTB_VO_CLK>;\n'
           '\t\t\tclock-names = "pix", "vo";\n'
           '\t\t\tresets = <&crg 0xd8 30>;\n'
           '\t\t\tstatus = "disabled";\n'
           '\t\t\tports { #address-cells = <1>; #size-cells = <0>;\n'
           '\t\t\t\tport@0 { reg = <0>; vdp_out_hdmi: endpoint { };\n'
           '\t\t\t\t};\n\t\t\t};\n\t\t};\n\n'
           '\t\thdmi: hdmi@8ce0000 {\n'
           '\t\t\tcompatible = "hisilicon,hi3798mv100-hdmi";\n'
           '\t\t\treg = <0x8ce0000 0x10000>;\n'
           '\t\t\tinterrupts = <GIC_SPI 88 IRQ_TYPE_LEVEL_HIGH>;\n'
           '\t\t\tclocks = <&crg HISTB_HDMI_CTRL_CLK>, <&crg HISTB_HDMI_PHY_CLK>;\n'
           '\t\t\tclock-names = "ctrl", "phy";\n'
           '\t\t\tresets = <&crg 0x10c 9>, <&crg 0x10c 8>, <&crg 0x110 4>;\n'
           '\t\t\treset-names = "base", "bus", "phy";\n'
           '\t\t\tstatus = "disabled";\n'
           '\t\t\tports { #address-cells = <1>; #size-cells = <0>;\n'
           '\t\t\t\tport@0 { reg = <0>; hdmi_in_vdp: endpoint {\n'
           '\t\t\t\t\tremote-endpoint = <&vdp_out_hdmi>; };\n\t\t\t\t};\n'
           '\t\t\t};\n\t\t};\n\n')
    return s.replace(marker,nodes+marker)
modified('arch/arm/boot/dts/hi3798mv100.dtsi',dtsi)

# 4) board dts: enable vdp+hdmi and link endpoints; ensure gpu okay + no mali-supply
def board(s):
    add=('\n&vdp {\n\tstatus = "okay";\n};\n\n'
         '&hdmi {\n\tstatus = "okay";\n};\n\n'
         '&vdp_out_hdmi {\n\tremote-endpoint = <&hdmi_in_vdp>;\n};\n')
    return s.rstrip('\n')+'\n'+add
modified('arch/arm/boot/dts/hi3798mv100-ec6108v9c.dts',board)

open(OUT,'w').writelines(parts)
print('wrote',OUT,os.path.getsize(OUT),'bytes')
