// SPDX-License-Identifier: GPL-2.0-only
/*
 * Hi3798MV100 on-chip Tsensor.
 *
 * Register sequence taken from the HiSilicon 4.4 SDK
 * drivers/hisilicon/thermal/hi3798cvx-thermal.c (get_sensor_value).
 * The vendor 3.10 kernel only exported /proc/hisi/msp/pm_temp; this
 * driver registers a standard thermal_zone so
 * /sys/class/thermal/thermal_zone0/temp works with ordinary tools.
 *
 * PMC base 0xF8A23000, PERI_PMC10 (+0x28) starts a conversion,
 * PERI_PMC12 (+0x30..+0x3c) returns eight 10-bit samples.
 *   temp_C = ((average - 125) * 165 / 806) - 40
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/thermal.h>
#include <linux/of.h>

#define PMC10		0x28
#define PMC12		0x30
#define PMC_START	0x6005
#define SAMPLE_COUNT	4

struct hi3798_tsensor {
	void __iomem *base;
	struct thermal_zone_device *tzd;
};

static int hi3798_tsensor_get_temp(struct thermal_zone_device *tz, int *temp)
{
	struct hi3798_tsensor *ts = tz->devdata;
	u32 acc = 0;
	int i, j;
	u32 val;

	writel(PMC_START, ts->base + PMC10);
	mdelay(16);
	for (j = 0; j < SAMPLE_COUNT; j++) {
		val = readl(ts->base + PMC12 + 4 * j);
		for (i = 0; i < 2; i++)
			acc += (val >> (16 * i)) & 0x3ff;
	}
	writel(0, ts->base + PMC10);
	acc /= 8;
	*temp = (((int)acc - 125) * 165 / 806 - 40) * 1000;
	return 0;
}

static struct thermal_zone_device_ops hi3798_tsensor_ops = {
	.get_temp = hi3798_tsensor_get_temp,
};

static int hi3798_tsensor_probe(struct platform_device *pdev)
{
	struct hi3798_tsensor *ts;
	struct resource *res;

	ts = devm_kzalloc(&pdev->dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	ts->base = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(ts->base))
		return PTR_ERR(ts->base);

	ts->tzd = thermal_zone_device_register("hi3798mv100-tsensor", 0, 0,
			ts, &hi3798_tsensor_ops, NULL, 0, 1000);
	if (IS_ERR(ts->tzd))
		return dev_err_probe(&pdev->dev, PTR_ERR(ts->tzd),
				     "failed to register thermal zone
");

	platform_set_drvdata(pdev, ts);
	dev_info(&pdev->dev, "Hi3798MV100 Tsensor registered
");
	return 0;
}

static int hi3798_tsensor_remove(struct platform_device *pdev)
{
	struct hi3798_tsensor *ts = platform_get_drvdata(pdev);

	thermal_zone_device_unregister(ts->tzd);
	return 0;
}

static const struct of_device_id hi3798_tsensor_of_match[] = {
	{ .compatible = "hisilicon,hi3798mv100-tsensor" },
	{ }
};
MODULE_DEVICE_TABLE(of, hi3798_tsensor_of_match);

static struct platform_driver hi3798_tsensor_driver = {
	.probe = hi3798_tsensor_probe,
	.remove = hi3798_tsensor_remove,
	.driver = {
		.name = "hi3798mv100-tsensor",
		.of_match_table = hi3798_tsensor_of_match,
	},
};
module_platform_driver(hi3798_tsensor_driver);

MODULE_AUTHOR("ec6108v9c-debian");
MODULE_DESCRIPTION("Hi3798MV100 on-chip temperature sensor");
MODULE_LICENSE("GPL");
