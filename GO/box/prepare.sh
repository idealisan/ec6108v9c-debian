#!/system/bin/sh
# 只布置文件与 command，不重启。
# 由用户按遥控器（force recovery）进入 recovery，避免 reboot recovery 写 BCB
# 覆盖 --update_package 参数。
set -e
mkdir -p /cache/recovery
if [ -f /data/update.zip ]; then
  cp -f /data/update.zip /cache/recovery/update.zip
else
  echo "缺少 /data/update.zip"; exit 1
fi
rm -f /cache/recovery/UPDATER_RAN.txt /cache/recovery/FLASH.txt /cache/recovery/ROLLBACK.txt
echo '--update_package=/cache/recovery/update.zip' > /cache/recovery/command
sync
echo "== /cache/recovery/command = $(cat /cache/recovery/command)"
echo "== 文件:"
ls -l /cache/recovery/
echo "== 现在请按遥控器进 recovery（不要用 reboot recovery）"
