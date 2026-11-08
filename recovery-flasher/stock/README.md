# stock/ — 原厂 recovery boot.img（方案的必需输入，无源码）

## 文件

- `recovery-stock.img` — 3,523,539 B，独立 Android `ANDROID!` boot.img（v0，page 2048）。
  - SHA-256 `f63f13b8d3d2a7cf55a13e91f3ace33b033a71a1364b9292e22959b3c88de96c`
  - 头字段：kernel 2,563,176 B @ `0x3e08000`、ramdisk 957,395 B @ `0x4e00000`、
    tags `0x3e00100`、cmdline `console=ttyAMA0,115200 blkdevparts=...`(Android 16 分区)。
  - kernel blob 是 legacy uImage（`Linux-3.10.0_s40`，load/ep `0x2000000`）；
    ramdisk 是 gzip(1f8b08) → newc cpio(070701)，53 项，含 `sbin/recovery`、`init.rc`、
    `ueventd.rc`、`res/images/*.png`。

## 为什么入库

用户明确决定：`docs/050` 的「改造原厂 recovery 用户态」方案**必须**用到原厂内核
（自带 hifb/VO/HDMI 显示驱动，是刷机态能点亮 HDMI 的唯一已验证途径），
而这颗 3.10 内核**没有源代码、无法重建**。因此这份二进制是本方案的**必需构建输入**，
用本仓库管理与保存，使 clone 仓库即可用 `bash recovery-flasher/build.sh` 复现，
不再依赖本机 `TMP/stock-rom-research/extracted/p03_recovery.img`（16 MiB 分区 dump，gitignored）。

## 来源与裁剪

从原厂整机备份 `ec6108v9c-stock-ROM-backup.zip` 的 `p03_recovery.img`(16 MiB 分区) 裁出：
该分区前 8 MiB 是计数器填充，`ANDROID!` boot.img 头在偏移 `0x800000`。
取 `[0x800000 : ramdisk_end]` 得到本文件——即**未改动的**原厂 kernel + ramdisk，
仅去掉分区前后的填充，`ANDROID!` 头因此落在文件偏移 0。
`repack.py` 用 magic 扫描自适应两种布局（仓库版偏移 0 / 分区版 `0x800000`）。

## 合法性 / 隐私

- 这是华为/海思机顶盒固件的二进制片段，仅作为本移植工程的技术研究所必需的输入，
  随仓库公开。内核 blob 与 ramdisk 在 `repack.py` 中被**逐字节保留**，不修改内核。
- 已扫描：不含本机绝对路径 / 用户名 / IP / 凭据（`strings` 复核）。

## 用途

`repack.py` 读它 → 替换 ramdisk 里 `sbin/recovery` 为我们自编的 `flasher` → 产出
`recovery-flash-boot.img`（改造版）与 `recovery-verify.img`（未改验证版）。
`bootm` 直接起 `ANDROID!` boot.img，短接触点上电即自动运行，零交互。
