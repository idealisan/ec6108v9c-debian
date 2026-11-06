U 盘救援包（hiboot 阶段，不依赖 recovery / 安卓 / 网络）
==========================================================

现状：recovery 反复重启，遥控器进 recovery 也是同一画面。
p11 原厂内核没动（68f8c213…），system/data 没动 —— 不是变砖。
坏的是两处：
  1. misc 里的 BCB 写着 boot-recovery，hiboot 每次都进 recovery；
  2. p3 里两份 recovery 的 ramdisk 都被我改过，hiboot 有
     "The recovery verify failed." 的 RSA 校验，两份都起不来。
所以救援必须：清 BCB + 把 p3 写回原厂。

!!! 关键：U 盘升级模式不是 recovery !!!
它发生在 hiboot（比 recovery 更早）。上电时按遥控器触发的是
hiboot 里的 "forceFlag / force update"（p1 里能查到这两个字符串），
然后 hiboot 读 U 盘根目录的 bootargs.bin 并执行 bootcmd。
recovery 坏了不影响这条路 —— 因为压根还没走到 recovery。

hiboot 字符串证据：
  detect forceFlag,force update
  recoverybootargs / bootargs.bin / bootargs crc failed !
  The recovery verify failed. / boot from first-recovery / second-recovery
社区 mv100-mdmo1g-usb-flash.zip 用的就是这套机制。

【操作】
1. U 盘格式化成 FAT32 / MBR。
2. 阶段 1：把 bootargs.bin 拷到 U 盘根目录（只需这一个文件）。
   断电 → 插 U 盘 → 上电，同时按住你平时进 recovery 的那个遥控器键
   （就是触发 forceFlag 的键，和以前一样，不需要短接触点）。
   bootcmd 做的事：mw.b 把 DDR 清零 → mmc write 写进 misc 前 4KB
   抹掉 BCB → reset。之后应该直接回原厂安卓。
3. 如果阶段 1 之后还是循环：阶段 2，把 bootargs-full.bin 改名为
   bootargs.bin（覆盖），并把 p03_stock.img（原厂 recovery 16MB）
   也拷到根目录，同样上电触发。它会清 BCB + 把 p3 写回原厂。

【为什么分两步】
阶段 1 只用 hiboot 内置命令，不读 U 盘大文件，最不容易失败；
阶段 2 的 fatload 若读失败，至少 BCB 已经清掉了，安卓能起。
p03_stock.img 的 md5 是 96643af0302e2765fabae0eaa322d824，
就是从这台设备上 dd 出来的原厂 p3。

【LBA 依据】原厂 16 分区 layout，512B 扇区
  misc     0x19000 （写 8 扇区 = 4KB，覆盖 BCB 的 1088 字节）
  recovery 0x2800  （0x8000 扇区 = 16MB）
与 docs/006-restore-to-stock.md 的恢复表一致。

【如果 U 盘这条路也不行】
那就只剩硬件手段：串口 TTL + HiTool，或短接触点进 BootROM 下载模式。
这两样你手上都没有，所以先别放弃 U 盘这条路 —— 它不需要短接，
只需要上电时按遥控器（和以前进 recovery 完全同一个动作）。

【恢复之后】
别再留 boot-recovery 的 BCB 尾巴。要做 Debian 就走干净的
"U 盘 bootargs.bin → mmc write" 路线，别再往 misc 里写 BCB，
也别改 p3 —— 保持 recovery 原厂，它就是你的救援通道。
