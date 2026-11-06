#!/system/bin/sh
# 用 BCB 触发 recovery 自动安装签名包（不需要遥控器、不需要菜单）
# 在 Android 的 root shell 里执行。
#
# 原理：AOSP get_args() 优先读 misc 分区 BCB 的 recovery 字段；
# 那里第一行是 recovery，第二行是 --update_package=...，
# 于是直接 install_package()，绕开 command 文件被跳过的问题，
# 也绕开华为菜单的包名白名单。
set -e
MISC=/dev/block/platform/hi_mci.1/by-name/misc
[ -e "$MISC" ] || MISC=/dev/block/mmcblk0p9

mkdir -p /cache/recovery
cp -f /data/update.zip /cache/recovery/update.zip
rm -f /cache/recovery/UPDATER_RAN.txt /cache/recovery/FLASH.txt /cache/recovery/ROLLBACK.txt
echo '--update_package=/cache/recovery/update.zip' > /cache/recovery/command

echo "== 写 BCB 到 $MISC"
dd if=/data/bcb.bin of="$MISC" bs=1088 count=1
sync

echo "== 重启（普通 reboot，由 BCB 自动进 recovery 并安装）"
reboot
