# 社区 Ubuntu 刷机包解剖（2026-11-06）

对象：`mv100-mdmo1g-usb-flash.zip`（295MB）。用户已用「触点接触 + U 盘」方式
刷入成功，证实这条路是最可靠的兜底通道。本报告为「改用社区同款引导/刷机方式、
但换成自定制 Debian」提供依据。

## 1. 引导链（社区同款，原样沿用）

```
p1 hiboot (fastboot.bin, LBA 0)
  -> 读 p2 bootargs.bin (LBA 0x800, 64KB = [4B LE CRC32][\0分隔env][补零])
  -> env.bootcmd = mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0
       (从 p6=LBA 0x7000 读 20MB 到 DDR 0x1FFFFC0 = 0x2000000-0x40)
  -> bootm 解析 uImage 头，payload 落在 load/entry 0x2000000
  -> 内核按 env.bootargs 启动
```

env.bootargs（`mv100/bootargs.bin`，写入 p2 的那份）：

```
model=mv100 console=ttyAMA0,115200 root=/dev/mmcblk0p7 rootfstype=ext4 rootwait
blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),
            20M(kernel),64M(busybox),512M(backup),-(ubuntu)
```

`bootargs9-32.bin` 是同一份但 root=p9（两级接力完成后切换用）。

**9 分区 LBA 表（512B 扇区）** —— 与原厂 16 分区完全不同：

| 分区 | 内容 | LBA | 大小 |
|---|---|---|---|
| p1 | boot / hiboot | 0x0 | 1M |
| p2 | bootargs | 0x800 | 1M |
| p3 | baseparam | 0x1000 | 4M |
| p4 | pqparam | 0x3000 | 4M |
| p5 | logo | 0x5000 | 4M |
| p6 | kernel (uImage) | 0x7000 | 20M |
| p7 | busybox (OpenWrt recoverybox) | 0x11000 | 64M |
| p8 | backup | 0x31000 | 512M |
| p9 | ubuntu (rootfs) | 0x131000 | 剩余全部 |

## 2. 刷机链（社区同款，原样沿用）

U 盘 FAT32/MBR，根目录放：

```
bootargs.bin          64KB 顶层刷机脚本（CRC32 头 + env）
fastboot.bin          p1 镜像（我们不使用，p1 保持不动）
mv100/
  fastboot.bin
  bootargs.bin        -> 写 p2
  baseparam.img       -> 写 p3
  pq_param.bin        -> 写 p4
  logo.img            -> 写 p5
  hi_kernel.bin       -> 写 p6
  recoverybox32.ext4  -> 写 p7（Android sparse）
  www_ecoo_top.ext4   -> 写 p8（Android sparse）
```

顶层 `bootargs.bin` 的 env 里每个分区一对 `loadfileX` / `flashpartitionX`：

```
loadfilek=fatload usb 0 0x1000000 mv100/hi_kernel.bin
flashpartitionk=mmc write 0x0 0x1000000 0x7000 0x7800
flashkernel=run loadfilek flashpartitionk
bootcmd=run flashfastboot; run flashbootargs; ...; run flashkernel;
        run flashrootfs; run flashbackup; reset
```

- `fatload usb 0 0x1000000 <file>` 把文件读到 DDR 16MB 处。
- `mmc write 0x0 0x1000000 <LBA> <扇区数>` 按固定 LBA 写裸分区。
- `mmc write.ext4sp 0x0 0x1000000 <LBA> <扇区数>` 直写 Android sparse v1 镜像
  （28B 头 + 12B chunk 头；RAW=0xCAC1 / FILL=0xCAC2 / DONT_CARE=0xCAC3）。
- 结尾 `reset` 重启，p1 hiboot 按 p2 的新 bootcmd 引导。

CRC32 算法已验证：`[4B LE CRC32 of bytes[4:]] + [NUL 分隔 key=value] + [补零到 64KB]`。
hiboot 里有 `bootargs.bin` / `bootargs crc failed !` / `recoverybootargs` 字符串，
CRC 不对会拒绝执行。

## 3. 两级接力（"奇怪的系统"，我们去掉）

p7 = OpenWrt 19.07 `recoverybox`（Hi-OpenWrt / histb 社区定制）：

- `/etc/rc.local` 唯一一行：`sh /etc/recovery.sh`
- `/etc/recovery.sh`：
  ```sh
  mkdir -p /backup
  mount -t ext4 /dev/mmcblk0p8 /backup
  gunzip -c /backup/backup-$arch.gz | dd of=/dev/mmcblk0p9 conv=fsync
  resize2fs /dev/mmcblk0p9
  dd of=/dev/mmcblk0p2 if=/etc/bootargs/bootargs9-32.bin bs=1024 count=1024
  dd of=/dev/mmcblk0p5 if=/etc/bootargs/logo.img bs=1024 count=4096
  sync; umount /backup; reboot
  ```
- p8 (`www_ecoo_top.ext4`, 512MB ext4) 里只有一个文件 `backup-32.gz`（283,965,843 B）。
  **实测它不是 gzip**：无 1f8b 魔数、无 gzip 尾部、前 1MB 熵接近 8、
  单字节/循环 XOR 都还原不出 gzip 头。文件名带 .gz 但内容像加密/自定义压缩。
- p9 的 Ubuntu 是 `Ubuntu-20.04.5-armhf-20260101-36b11.img`。
- recoverybox 自带 dropbear(22, `/etc/config/dropbear` 允许 root 密码登录)、
  LuCI、busybox 全套（ifconfig/ip/udhcpc/e2fsck/resize2fs/mke2fs/insmod...）。

这套两级接力脆弱且不可审计。我们的 Debian 包**直接把 rootfs sparse 写进 p9**，
不需要 p7/p8，也不需要改 p2 两次。

## 4. 内核

```
uImage: magic 0x27051956, comp=none, load=entry=0x2000000
name:   Linux-4.4.35_ecoo_81082668
size:   10,862,583 B (payload 是 raw ARM Image + 尾附 DTB)
```
DTB 里 `chosen.bootargs` 自带 `root=/dev/mmcblk0p9 ... blkdevparts=...` 兜底，
hiboot 传入的 env.bootargs 优先。内置 hieth 网口、himciv200 eMMC、hifb HDMI、
mali-450、hix5hd2-ir、ext4。

我们的 CI 用主线 6.x（`build-kernel.sh`）产出同格式 uImage（zImage+DTB 包
uImage 头，load 0x2000000），完全兼容社区 `bootm 0x1FFFFC0`。主线内核无 HDMI
显示驱动，但本方案的目标是 SSH/telnet，不依赖屏幕。

## 5. 我们的 Debian 包设计

**保留**：p1 hiboot（不写）、p2 的 bootcmd 形态、9 分区 LBA 表、
U 盘 `bootargs.bin` + `mv100/` 刷机脚本格式、`mmc write.ext4sp` sparse 写入。

**替换**：p6 内核换成 CI 编译的主线 6.x uImage；p9 换成 Debian armhf rootfs
（含 openssh-server + busybox telnetd + 常用工具）转的 sparse 镜像。

**去掉**：两级接力（p7 recoverybox / p8 backup 都不写）、p1 写入、
`bootargs9-32.bin` 二次切换。p2 只写一次，直接 root=p9。

产物（GitHub Actions release）：
- `mv100-mdmo1g-debian-usb-flash-<UTC>.zip` —— 拷到 U 盘即用
- `hi_kernel.bin`（uImage）、`debian-rootfs-armhf-bookworm.tar.gz`、`modules.tar.gz`
- `SHA256SUMS.txt`

## 6. 参考来源

- `docs/001-boot-and-flash-analysis.md`（初次逆向）
- `docs/003-usb-format-tool-analysis.md`（U 盘格式）
- 本地解包产物：`flash_analysis/`（`www_ecoo_top.raw` 用 `debugfs` 解析、
  `recoverybox.raw` 用 `7zz` 解析）
