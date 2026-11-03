# 刷回原厂（回滚）方案

- 编写日期：2026-11-03
- 适用设备：EC6108V9C（Hi3798MV100，原厂 Android 4.4.2 / 内核 3.10.0_s40）
- 依赖：本机已完成的整机备份（17 个镜像，7.3 GB，含 md5）
- 相关文档：`001-boot-and-flash-analysis.md`、`005-stock-device-analysis.md`

## 1. 备份资产

| 文件 | 大小 | 分区 | 写回偏移（512B 扇区） |
|---|---|---|---|
| p01_fastboot.img | 1 MiB | fastboot（hiboot） | 0x0 |
| p02_bootargs.img | 4 MiB | bootargs（启动环境） | 0x800 |
| p03_recovery.img | 16 MiB | recovery | 0x2800 |
| p04_deviceinfo.img | 1 MiB | deviceinfo | 0xA800 |
| p05_baseparam.img | 4 MiB | baseparam | 0xB000 |
| p06_pqparam.img | 4 MiB | pqparam | 0xD000 |
| p07_logo.img | 4 MiB | logo | 0xF000 |
| p08_fastplay.img | 16 MiB | fastplay | 0x11000 |
| p09_misc.img | 8 MiB | misc | 0x19000 |
| p10_factory.img | 24 MiB | factory | 0x1D000 |
| p11_kernel.img | 12 MiB | kernel（Android boot.img） | 0x29000 |
| p12_iptv_data.img | 8 MiB | iptv_data | 0x2F000 |
| p13_backup.img | 340 MiB | backup | 0x33000 |
| p14_cache.img | 340 MiB | cache | 0xDD000 |
| p15_system.img | 520 MiB | system | 0x187000 |
| p16_userdata_a/b/c.img | 2048+2048+2058 MiB | userdata | 0x4E0000 起 |

userdata 起始偏移：1302 MiB = 2666496 扇区 = 0x28B000（按原厂布局计算，见 005 文档）。

## 2. 先判断当前处于哪种情况

| 现象 | 场景 |
|---|---|
| Debian 能启动、能 SSH/串口登录 | A |
| 开机无显示/停在 hiboot，但 p1 未被改动过 | B |
| 开机完全无反应，串口无任何输出 | C |
| 能进 Debian 但分区/文件系统异常 | A 或 D |

## 3. 场景 A：Debian 还能启动（最快）

在 Debian 里插上备份 U 盘（FAT32），挂载后直接写回：

```sh
mkdir -p /mnt/usb
mount -t vfat /dev/sda1 /mnt/usb        # 或 /dev/sda（无分区表时）
cd /mnt/usb/backup

# 先写数据分区，最后写 bootloader
for p in 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
  case $p in
    02) lba=0x800;;   03) lba=0x2800;;  04) lba=0xA800;; 05) lba=0xB000;;
    06) lba=0xD000;;  07) lba=0xF000;;  08) lba=0x11000;;09) lba=0x19000;;
    10) lba=0x1D000;; 11) lba=0x29000;; 12) lba=0x2F000;;13) lba=0x33000;;
    14) lba=0xDD000;; 15) lba=0x187000;;
  esac
  echo "restore p$p"
  dd if=p$p_*.img of=/dev/mmcblk0 bs=512 seek=$((lba)) conv=fsync
done
dd if=p01_fastboot.img of=/dev/mmcblk0 bs=512 seek=0 conv=fsync
sync; reboot
```

> 注意：上面的 `p$p_*.img` 仅示意，实际文件名是 `p02_bootargs.img` 等，逐个写更稳妥。

userdata 也一并恢复：

```sh
dd if=p16_userdata_a.img of=/dev/mmcblk0 bs=1M seek=1302 conv=fsync
dd if=p16_userdata_b.img of=/dev/mmcblk0 bs=1M seek=$((1302+2048)) conv=fsync
dd if=p16_userdata_c.img of=/dev/mmcblk0 bs=1M seek=$((1302+4096)) conv=fsync
```

## 4. 场景 B：Debian 起不来，但 hiboot 正常（用 U 盘还原包）

前提：p1 未被本次刷机改动（使用 `stock-hiboot` 版本刷机时成立），或 SDK hiboot 仍可用。

步骤：

1. 备份 U 盘（已含 `backup/` 目录与 17 个镜像）根目录放入 release 里的
   `mv100-mdmo1g-stock-restore-*.zip` 解压出的 `bootargs.bin`（与 `backup/` 同级）。
2. 断电，插 U 盘，按住恢复键上电。
3. 脚本按 p2→p15 顺序写回，**最后写 p1**，然后自动复位。
4. 重启后应回到原厂 Android。

还原包内容（`bootcmd`）：

```
run r2; run r3; ...; run r15; run r1; reset
```

每条 `rN` = `fatload usb 0 0x1000000 backup/pNN_xxx.img` + `mmc write 0 0x1000000 <lba> <cnt>`。
p13/p14/p15 较大（340/340/520 MB），但 1 GB DDR 足够（加载地址 16 MB 起）。

userdata 不在还原包内（6 GB 无法整块载入 DDR）。原厂 Android 首次启动会重新初始化 /data；
若需完整还原用户数据，见场景 A 的 dd 命令。

## 5. 场景 C：彻底变砖（p1 损坏 / 串口无输出）

这是唯一需要外部工具的情况。EC6108V9C 的 BootROM 支持串口+USB 下载模式：

1. 准备 USB 转 TTL（3.3V），接主板 UART（ttyAMA0，115200 8N1）。
2. 断电，短接/按住强制下载组合（部分板子需短接 eMMC CLK 或按住复位），上电，
   串口应出现 BootROM 的下载提示。
3. 电脑用 **HiTool**（海思烧写工具，Windows）选择 hi3798mv100 芯片、
   加载备份的 `p01_fastboot.img`（或 SDK 的 fastboot-burn.bin）写入 fastboot 分区。
4. p1 恢复后，其它分区可回到场景 B 用 U 盘还原。

> HiTool 与驱动不在本仓库内，属外部工具；此处仅记录流程。

## 6. 恢复后的自检

1. 串口 115200 应能看到 hiboot 打印与内核启动日志；
2. 原厂桌面（`com.xinjing.launcher` / 移动激活页）出现；
3. `adb connect <ip>:5555` 能连上，`getprop ro.build.version.incremental` 应为 `V.890.26`；
4. 分区布局应回到 005 文档中的原厂表（`cat /proc/cmdline` 检查）。

## 7. 风险提示

- 写 p1 时若断电，可能无法启动，需要场景 C 的串口救砖；
  因此所有还原流程都把 p1 放在最后一步。
- 原厂 `verify=n`（签名校验关闭），恢复镜像无需签名，但也意味着没有兜底校验。
- 每次刷机前建议再备份一次当前状态（至少 p1、p2、p11、p15）。
- 备份文件请至少保留两份（U 盘 + 独立磁盘），md5 清单随备份一起保存。
