U 盘救援包（社区 Ubuntu 包同款机制）
====================================

现在的状态：设备反复进 recovery / 进不了安卓。
原因：misc 分区的 BCB 里写着 boot-recovery，recovery 异常退出后
没走 finish_recovery()，hiboot 每次读到它就再进 recovery。
这不是变砖 —— p11 原厂内核没动（68f8c213…），system/data 也没动。

原理（社区 mv100-mdmo1g-usb-flash.zip 就是这么做的）：
U 盘根目录放一个 bootargs.bin（64KB，4字节 CRC32 头 + NUL 分隔的
key=value 环境变量）。hiboot 在 U 盘升级模式里读它，执行 bootcmd：
    fatload usb 0 0x1000000 <文件>     ; 从 U 盘读到 DDR
    mmc write 0 0x1000000 <LBA> <扇区数> ; 按 LBA 写 eMMC
    reset
不经过 recovery、不验签、不需要安卓、不需要网络。

【方法 A：先试最省事的，不用短接】
断电，用你之前进 recovery 的遥控器办法进菜单，选 6. Reboot。
只要 recovery 这次正常走完，它会清掉 BCB，就能回安卓。
如果选完 Reboot 还是循环，再用方法 B。

【方法 B：U 盘救援，需要短接触点进 U 盘升级模式】
1. U 盘格式化成 FAT32 / MBR。
2. 把下面文件拷到 U 盘根目录：
     bootargs.bin      （最小版，只清 BCB）
     misc_zero.bin     （4KB 全零）
   如果还想把 recovery 也还原成原厂，另外拷：
     bootargs-full.bin 改名为 bootargs.bin（覆盖上面那个）
     p03_stock.img     （原厂 recovery 16MB，来自本机备份）
3. 断电，插 U 盘，短接触点上电（和社区包刷机同一个入口）。
4. 等它自动写完并重启（bootcmd 末尾是 reset）。拔掉 U 盘再开机，
   应该直接回原厂安卓。

两个版本的区别：
  最小版  ：只清 BCB，p3 保留我们改过的双公钥（原厂 key + 我们的 key）。
            以后 recovery 的 U 盘刷机能力仍在，且我们的签名包也能刷。
  完全恢复：清 BCB + 把 p3 写回原厂镜像，回到刷机前的完全原厂状态。
            想彻底重来就用这个。

LBA 依据（原厂 16 分区 layout，512B 扇区）：
  misc      = 0x19000   （写 8 扇区 = 4KB，覆盖 BCB 的 1088 字节）
  recovery  = 0x2800    （0x8000 扇区 = 16MB）
这两个偏移和 docs/006-restore-to-stock.md 里的恢复表一致。

注意：
  - 不要放 FLASH.txt / ROLLBACK.txt，救援包不涉及它们。
  - 短接不稳定就多试几次，这是唯一不依赖系统的入口。
  - 恢复后如果要继续做 Debian，从"双 key + BCB 触发"重新开始，
    但这次别留 boot-recovery 的 BCB：让 install 成功走完，
    或在 recovery 菜单里正常选 Reboot 收尾。
