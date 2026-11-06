就照这个做（不需要 U 盘，全程走 /cache）
==========================================

设备现状（2026-11-06 已用 ADB 核对）：
  IP 192.168.3.229，adb root 可用，p11 与备份一致（68f8c213…），
  p3 的 boot.img 在偏移 0（另有 8MB 处一份旧 recovery，保持不变），
  U 盘没插 -> 所有文件放 eMMC 的 /cache/recovery/。

  GO/box/       -> 推到盒子 /data/
  GO/usb/       -> update.zip 也推到盒子 /data/（不是插 U 盘）
  GO/step2/     -> 第 1 步成功后，再推到 /cache/recovery/
  GO/rollback/  -> 回滚时推到 /cache/recovery/

第 1 步（验证，不写 p11）—— 已执行完毕
  p3 已换成我们的公钥，/data/p03_stock.img 是原厂备份，
  /cache/recovery/update.zip 与 command 已布置好。
  最后一步需要你本人操作：按遥控器进 recovery（force recovery）。
  不要用 reboot recovery！它会写 BCB 的 boot-recovery，把
  --update_package 参数挤掉（2026-11-06 实测：recovery 起来了但没执行包）。

  判定（recovery 跑完会重启回 Android）：
  adb connect 192.168.3.229:5555
  adb shell cat /cache/recovery/UPDATER_RAN.txt
  有内容 = 签名与通道都通了。这一步 p11 完全没动。

第 2 步（确认成功后再刷内核）
  adb push GO/step2/rescue-boot.img GO/step2/FLASH.txt /cache/recovery/
  adb shell sh /data/again.sh

  update-binary 先把 p11 备份成 /cache/recovery/p11_stock.img
  （大小不对就中止），再写 rescue-boot.img 到 p11，然后重启。
  开机：屏幕彩色 LINUX / PROBE OK，telnet 192.168.3.240。

回滚
  adb push GO/rollback/ROLLBACK.txt /cache/recovery/
  （删掉 /cache/recovery/FLASH.txt，p11_stock.img 已在那里）
  adb shell sh /data/again.sh   -> 写回原厂 p11 -> 回 Android

  想连 recovery 也还原：
  adb shell sh /data/9-restore-p3.sh

文件说明
  update.zip         已用我们的私钥签名（SHA-1），verify 通过
  p3_keyswap.img     基于设备当前 p3 生成，只改了 res/keys；
                     8MB 处的 second-recovery 逐字节未变
  stock_p11.img      原厂 p11 本地备份（md5 68f8c213…）
