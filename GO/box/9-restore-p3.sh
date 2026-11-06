#!/system/bin/sh
# 在 Android（root）里执行：把原厂 recovery 写回去（随时可用）
set -e
P3=/dev/block/platform/hi_mci.1/by-name/recovery
[ -e "$P3" ] || P3=/dev/block/mmcblk0p3
[ -f /data/p03_stock.img ] || { echo "没有 /data/p03_stock.img"; exit 1; }
dd if=/data/p03_stock.img of="$P3" bs=4096
sync
echo "== 原厂 recovery 已恢复"
