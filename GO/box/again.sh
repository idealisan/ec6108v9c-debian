#!/system/bin/sh
# 再触发一次升级（第 2 步 / 回滚用）：不碰 p3，只写命令并进 recovery
set -e
mkdir -p /cache/recovery
if [ -f /data/update.zip ]; then cp -f /data/update.zip /cache/recovery/update.zip; fi
rm -f /cache/recovery/UPDATER_RAN.txt
echo '--update_package=/cache/recovery/update.zip' > /cache/recovery/command
sync
echo "== 命令：$(cat /cache/recovery/command)"
reboot recovery
