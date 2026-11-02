# EC6108V9C 刷 Debian — 分析进展报告

- 日期：2026-11-02
- 分析对象：`mv100-mdmo1g-usb-flash.zip`（社区刷机包，295MB）
- 分析工作目录：本地 `flash_analysis/`（解包产物、unsparse 脚本、raw 镜像，未入库）
- 目标：弄清该平台引导与刷机机制，为制作 Debian(armhf) 刷机包提供参考

## 1. 平台识别

| 项目 | 结论 | 依据 |
|---|---|---|
| SoC | HiSilicon Hi3798MV100 | hiboot 内 DDR 配置名 `hi3798mdmo1g_hi3798mv100_ddr3_1gbyte_16bitx2_4layers_emmc.reg` |
| CPU | 4× ARM Cortex-A7（32 位 armv7） | 内核尾部 DTB：`compatible = "arm,cortex-a7"` × 4 |
| 内存 | 1GB DDR3（16bit×2），`mem=1G mmz=ddr,0,0,48M vmalloc=500M` | bootargs 环境变量 |
| 存储 | eMMC，**无 MBR/GPT 分区表** | 分区由内核命令行 `blkdevparts=` 定义 |
| 厂商系统 | ECOO（www.ecoo.top）IPTV 终端，构建号 81082668 | fastboot 版本串 `Fastboot 3.3.0_ecoo_81082668-dirty`、内核名 `Linux-4.4.35_ecoo_81082668` |
| bootloader | HiSTB 风格私有 "fastboot"（hiboot），非标准 U-Boot，但命令集兼容 | 二进制字符串分析 |

## 2. 刷机包内容

```
mv100-mdmo1g-usb-flash.zip
├── bootargs.bin          64KB  顶层=U盘刷机脚本（hiboot 环境变量，含 CRC 头）
├── fastboot.bin         527KB  顶层=hiboot 副本（2023-10 版，救砖/参考用）
└── mv100/                      被写入盒子的目标镜像
    ├── fastboot.bin      hiboot 本体（2025-08-26 构建）→ 写 p1
    ├── bootargs.bin      盒子用的环境变量（root=p7）→ 写 p2
    ├── baseparam.img     显示参数 → 写 p3
    ├── pq_param.bin      画质参数 → 写 p4
    ├── logo.img          开机 logo → 写 p5
    ├── hi_kernel.bin     Linux 4.4.35_ecoo 内核 uImage（2026-04-10）→ 写 p6
    ├── recoverybox32.ext4  Android sparse → 64MB OpenWrt → 写 p7
    └── www_ecoo_top.ext4   Android sparse → 512MB backup 分区 → 写 p8
```

## 3. 引导链

```
eMMC LBA0 (p1 boot, 1MB)     hiboot (fastboot.bin)
   ↓ 读取 p2 bootargs 分区（64KB 环境变量，头部 CRC32 校验）
   ↓ bootcmd = mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0
   ↓ 从 LBA 0x7000 (14MB) 读 ≤20MB 内核到 DDR 32MB 处，bootm 启动
hi_kernel.bin（uImage，raw ARM Image，未压缩）
   ├─ Load/Entry: 0x2000000
   ├─ DTB 附加在镜像尾部：offset 0xa59d50，8935 字节（hi3798mv100-series）
   └─ DTB 内置 chosen.bootargs（root=/dev/mmcblk0p9 兜底）；
      hiboot 传入的环境变量 bootargs 优先生效（决定实际 root=）
   ↓
rootfs：由 bootargs 的 root= 决定（p7 recoverybox 或 p9 主系统）
```

## 4. 分区表（内核命令行定义，盘上无分区表）

`blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),20M(kernel),64M(busybox),512M(backup),-(ubuntu)`

| 分区 | 大小 | 起始偏移 | 刷写 LBA | 内容 |
|---|---|---|---|---|
| p1 boot | 1M | 0 | `0x0` | hiboot（fastboot.bin） |
| p2 bootargs | 1M | 1M | `0x800` | 64KB 环境变量 |
| p3 baseparam | 4M | 2M | `0x1000` | 显示参数 |
| p4 pqparam | 4M | 6M | `0x3000` | 画质参数 |
| p5 logo | 4M | 10M | `0x5000` | 开机 logo |
| p6 kernel | 20M | 14M | `0x7000` | 内核 uImage |
| p7 busybox | 64M | 34M | `0x11000` | recoverybox（OpenWrt 19.07.10 armvirt/32） |
| p8 backup | 512M | 98M | `0x31000` | www_ecoo_top.ext4 |
| p9 ubuntu | 剩余全部 | 610M | `0x131000` | 主系统 |

注意：所有刷写偏移都是**固定 LBA（512B 扇区）**，与上述命令行分区完全对应。

## 5. 刷机机制：两级接力

### 5.1 第一级 — hiboot U 盘刷机

hiboot 支持从 U 盘读取 `bootargs.bin` 覆盖内置环境执行（二进制内可见 `recoverybootargs`、`bootargs crc failed !` 等路径）。zip 根目录的 `bootargs.bin` 就是刷机脚本，其 `bootcmd` 依次执行（全部 `fatload usb 0 0x1000000 mv100/xxx` 加载到 DDR 16MB 后按 LBA 写入）：

| 动作 | 命令 | 目标 LBA | 长度(扇区) |
|---|---|---|---|
| 刷 hiboot | `mmc write 0 0x1000000 0x0 0x440` | 0x0 | 0x440 |
| 刷 bootargs | `mmc write 0 0x1000000 0x800 0x80` | 0x800 | 0x80 |
| 刷 baseparam | `mmc write 0 0x1000000 0x1000 0xc` | 0x1000 | 0xc |
| 刷 pqparam | `mmc write 0 0x1000000 0x3000 0x8b` | 0x3000 | 0x8b |
| 刷 logo | `mmc write 0 0x1000000 0x5000 0x120` | 0x5000 | 0x120 |
| 刷 kernel | `mmc write 0 0x1000000 0x7000 0x7800` | 0x7000 | 0x7800 |
| 刷 p7 | `mmc write.ext4sp 0 0x1000000 0x11000 0x20000` | 0x11000 | 0x20000 |
| 刷 p8 | `mmc write.ext4sp 0 0x1000000 0x31000 0x100000` | 0x31000 | 0x100000 |

写完 `reset` 重启 → root=p7 进入 recoverybox。

`mmc write.ext4sp` 为 hiboot 私有命令：**直接写入 Android sparse 镜像**（标准 sparse v1 格式：文件头 28 字节，chunk 头 12 字节，chunk 类型 RAW=0xCAC1 / FILL=0xCAC2 / DONT_CARE=0xCAC3 / CRC32=0xCAC4）。

### 5.2 第二级 — recoverybox (p7) 自动接力

recoverybox 是 OpenWrt 19.07.10（armvirt/32，cortex-a15 neon-vfpv4 用户态）+ ECOO 定制：

- `/etc/rc.local` → `sh /etc/recovery.sh`（开机自动执行）：
  ```sh
  mount -t ext4 /dev/mmcblk0p8 /backup
  gunzip -c /backup/backup-32.gz | dd of=/dev/mmcblk0p9   # 恢复主系统到 p9
  resize2fs /dev/mmcblk0p9
  dd of=/dev/mmcblk0p2 if=/etc/bootargs/bootargs9-32.bin  # 切换 bootargs → root=p9
  dd of=/dev/mmcblk0p5 if=/etc/bootargs/logo.img          # 写 logo
  reboot
  ```
- 带 LuCI Web UI（ecoo 定制 cgi-upload/cgi-exec/cgi-download/cgi-backup，指向 /usr/libexec/cgi-io）+ dropbear SSH（默认 192.168.1.1）
- 内置 `/etc/bootargs/bootargs9-32.bin`：`root=/dev/mmcblk0p9` 的环境变量，用于切换主引导

## 6. 关键格式细节（自制刷机包必需）

### 6.1 bootargs.bin 格式 — 已验证

```
[4 字节小端 CRC32(其余全部 65532 字节)] + [\0 分隔的 key=value 环境变量串] + [填充至 64KB]
```

三个样本（顶层 bootargs.bin、mv100/bootargs.bin、bootargs9-32.bin）全部验证：
`zlib.crc32(data[4:]) == struct.unpack('<I', data[:4])[0]`

hiboot 校验失败会拒绝执行（`bootargs crc failed !`）。**自制环境变量必须重算头部 CRC32。**

### 6.2 环境变量示例（盒子侧，root=p9 版本）

```
bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000;bootm 0x1FFFFC0
bootargs=model=mv100 console=ttyAMA0,115200 root=/dev/mmcblk0p9 rootfstype=ext4 rootwait blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),20M(kernel),64M(busybox),512M(backup),-(ubuntu)
```

另有按内存容量的变体（bootargs_512M/1G/2G/768M/1536M/3840M），mmz 预留各不相同。

### 6.3 hiboot 命令集（与刷机相关）

`mmc write <dev> <addr> <blk#> <cnt>` / `mmc write.ext4sp <dev> <addr> <blk#> <cnt>` / `fatload usb 0 <addr> <path>` / `crc32 <addr> <len>` / `bootm` / `reset`；支持 env 变量与 `run`。USB fastboot 协议亦可用（`fastboot#` 提示符）。

## 7. 重要发现与疑点

1. **backup-32.gz 是加密数据**：p8 内唯一文件（283MB），全文件熵 ≈7.99 bits/byte，无 gzip 魔数。`recovery.sh` 的 `gunzip -c` 实际会失败，dd 写入 0 字节，p9 内容原样保留。
   → 该社区包的真实作用是"**重建引导设施（hiboot/bootargs/kernel/recoverybox）+ 把 bootargs 切回 p9**"，主系统保持不变；做 Debian 包时 **p8 可完全无视**。
2. hiboot 如何触发 U 盘 bootargs.bin 执行（按键组合 / 自动检测）尚未从二进制完全确认，仅有 `recoverybootargs`/`bootargs.bin` 字符串证据；需真机验证（通常为按住前面板/复位键上电）。
3. 顶层 fastboot.bin（2023-10）与 mv100/fastboot.bin（2025-08）仅差极小部分（cmp 到 0x205d 处才不同），推测顶层为原厂 hiboot 副本（救砖参考）。
4. 内核为 raw 未压缩 Image + 尾附 DTB；hiboot 传参方式（ATAG 覆盖 DTB chosen）推断自"p2 环境变量优先于 DTB 内置 root=p9"的现象，未从内核配置直接验证。

## 8. Debian 刷机包方案（建议）

**方案 A（推荐，最小改动）**

1. 复用 `mv100/fastboot.bin`（hiboot）与 `mv100/hi_kernel.bin`（4.4.35 armhf，DTB 已附尾部）；
2. 构建 Debian armhf rootfs（debootstrap，内核模块从 hi_kernel.bin 对应版本提取，或直接无模块运行 + 固件按需）；
3. `mke2fs -d` 生成 ext4 → 转 Android sparse v1（img2simg 或自写生成器，格式已逆向，见 flash_analysis/unsparse.py 反向操作）；
4. 自制顶层 `bootargs.bin` 刷机脚本，新增：
   ```
   loadfileu=fatload usb 0 0x1000000 mv100/debian.ext4
   flashpartitionu=mmc write.ext4sp 0 0x1000000 0x131000 <p9扇区数>
   ```
   并把 `flashbootargs` 的目标换成 `root=/dev/mmcblk0p9` 的新 bootargs（重算头部 CRC32）；
5. p7 recoverybox 保留不动，作为救援/回退系统（改 p2 即可切回 root=p7）。

**方案 B（照搬两级结构）**：把 Debian rootfs gzip 后放入自建 512MB ext4（挂 p8 位置），靠 recovery.sh 解压到 p9。仅在需要"Web 上传镜像"体验时才有意义，工作量更大。

**风险与注意**

- eMMC 无分区表：任何工具（fdisk/parted）写 MBR 都会破坏 hiboot 预期布局；
- bootargs 头部 CRC32 不对 → hiboot 拒绝，刷机脚本不执行；
- p6 内核分区上限 20MB（LBA 0x7000 起 0x7800 扇区写入长度按文件实际大小）；
- console=ttyAMA0,115200 为调试串口（DTB: uart@0xf8b00000）。

## 9. 工具与分析产物位置

- 解包与 raw 镜像：本地 `flash_analysis/` 目录（未入库）
  - `unsparse.py`（sparse → raw 转换器，已验证两种镜像）
  - `recoverybox.raw` / `www_ecoo_top.raw`（可用 `debugfs -R "ls -l /" xxx.raw` 浏览，e2fsprogs）
  - `kernel.dtb` / `kernel.dts`（从 hi_kernel.bin 尾部提取的反编译 DTB）
  - `bootargs9-32.bin`（从 recoverybox 提取的 root=p9 环境变量样本）
- 原始刷机包：`mv100-mdmo1g-usb-flash.zip`（本地文件）

## 10. 待办

- [ ] 真机验证 U 盘刷机触发方式（按键组合）
- [ ] 验证 hiboot 是否接受任意 CRC 正确的 bootargs.bin（自制脚本能否直接跑）
- [ ] Debian armhf rootfs 构建并转 sparse 实测
- [ ] 串口接线确认（DTB 显示 3 个 uart 节点，调试口通常为 uart@0xf8b00000）
- [ ] 若沿用 4.4.35 内核：确认 Debian 版本兼容性（buster 无碍；bullseye 起 systemd 对老内核支持需验证）
