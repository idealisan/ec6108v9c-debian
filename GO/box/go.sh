#!/system/bin/sh
# 第 1 步：换 recovery 公钥 + 布置签名包 + 写触发命令 + 进 recovery
# 在 Android 的 root shell 里执行（ADB 或 telnet）
#
# 只改 p3；p11 一个字节都不动，失败断电重开就是原厂 Android。
# 全程走 eMMC 的 /cache 分区，不需要 U 盘。
set -e
P3=/dev/block/platform/hi_mci.1/by-name/recovery
[ -e "$P3" ] || P3=/dev/block/mmcblk0p3
IMG=/data/p3_keyswap.img
PKG=/data/update.zip

[ -f "$IMG" ] || { echo "缺少 $IMG"; exit 1; }
[ -f "$PKG" ] || { echo "缺少 $PKG"; exit 1; }

if [ ! -f /data/p03_stock.img ]; then
  echo "== 备份原厂 recovery -> /data/p03_stock.img"
  dd if="$P3" of=/data/p03_stock.img bs=4096
  sync
fi
echo "== 原厂 recovery 备份："
/system/bin/busybox md5sum /data/p03_stock.img

echo "== 写入换过公钥的 recovery"
dd if="$IMG" of="$P3" bs=4096
sync

echo "== 布置签名包与触发命令"
mkdir -p /cache/recovery
cp -f "$PKG" /cache/recovery/update.zip
rm -f /cache/recovery/UPDATER_RAN.txt /cache/recovery/FLASH.txt /cache/recovery/ROLLBACK.txt
echo '--update_package=/cache/recovery/update.zip' > /cache/recovery/command
cat /cache/recovery/command; echo
sync

echo "== 进 recovery"
reboot recovery
