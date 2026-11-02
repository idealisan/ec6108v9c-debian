# ec6108v9c-debian

给华为悦盒 EC6108V9C（HiSilicon Hi3798MV100，4×Cortex-A7，1GB DDR3，eMMC）刷 Debian armhf 的构建仓库。

本仓库只做两件事：

1. 逆向记录：`docs/` 下的分析报告，说明该平台的引导链、分区表、刷机机制；
2. 自动化构建：GitHub Actions 从源码构建 **内核 / Debian rootfs / U 盘刷机包** 三个产物，并按 UTC 时间戳发布到 Release。

## 目录结构

    .github/workflows/build-release.yml   CI：构建 + 发布 release
    scripts/build-kernel.sh               编译内核（uImage + modules）
    scripts/build-rootfs.sh               debootstrap 构建 Debian armhf rootfs
    scripts/make-flash-package.sh         组装 U 盘刷机包（ext4 -> sparse -> zip）
    scripts/mkbootargs.py                 生成 bootargs.bin（含 hiboot 校验的 CRC32 头）
    scripts/img2simg.py                   ext4 -> Android sparse（hiboot write.ext4sp 用）
    scripts/env/runtime.env               写入 p2 的运行时环境变量（root=/dev/mmcblk0p9）
    third_party/linux-hi3798mv100         内核源码子模块（固定 commit）
    docs/report.md                        刷机包引导/刷机机制逆向分析
    docs/mainline-kernel-debian-survey.md 主线内核 + Debian rootfs 路线调查

## 内核源码

`third_party/linux-hi3798mv100` 是 [loonpn/ec6108v9c-linux-kernel](https://github.com/loonpn/ec6108v9c-linux-kernel)
的浅克隆子模块，固定在 commit `8677b4069`（Linux 6.3.0-rc5 + hi3798mv100 移植补丁）。

CI 里用 `git submodule update --init --depth 1` 拉取，不拉完整历史。

## 产物

每次构建发布一个 release，标题形如：

    20261102T181500Z · debian12-armhf + linux-6.3.0-rc5 (hi3798mv100) + usb-flash

资产：

| 文件 | 说明 |
|---|---|
| `mv100-mdmo1g-debian-usb-flash-*.zip` | U 盘刷机包（bootargs.bin + mv100/） |
| `hi_kernel.bin` | 内核 uImage（zImage + 尾附 DTB，load 0x2000000） |
| `modules.tar.gz` | 内核模块（/lib/modules） |
| `debian-rootfs-armhf-bookworm.tar.gz` | 根文件系统 tar（参考用，不直接刷） |
| `SHA256SUMS.txt` | 校验和 |

## 刷机方式

1. U 盘格式化为 FAT32，把刷机 zip 解压到根目录；
2. 盒子断电，插入 U 盘，按住恢复键上电，让 hiboot 读取 U 盘根目录的 `bootargs.bin`；
3. 脚本依次写入 p6（内核）、p9（rootfs）、p2（bootargs），然后复位；
   p1/p3/p4/p5/p7/p8 不动（原 hiboot、显示参数、logo、救援系统均保留）；
4. 重启后进入 p9 上的 Debian：串口 `ttyAMA0 115200`，root 密码见 release notes；
   首次启动自动 `resize2fs` 扩容。

分区布局（内核命令行 `blkdevparts` 定义，盘上无分区表）：

    p1 boot 1M@0 · p2 bootargs 1M@1M · p3 baseparam 4M@2M · p4 pqparam 4M@6M
    p5 logo 4M@10M · p6 kernel 20M@14M · p7 busybox 64M@34M · p8 backup 512M@98M
    p9 ubuntu 剩余@610M

## 风险

- 刷机有变砖风险，务必先备份；
- 主线移植无 HDMI/视频解码驱动，只能串口/SSH 使用；
- 该 U 盘脚本依赖盒子原有的 hiboot；若 p1 的 hiboot 被破坏，需要 HiTool/串口救砖。
