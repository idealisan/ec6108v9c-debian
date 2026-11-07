# EC6108V9C Debian 刷机手册（018）

> 适用产物：GitHub Release build-<时间戳> 里的 mv100-mdmo1g-debian-usb-flash-<时间戳>.zip
> 注意：本方案回收了原 512M backup 分区并入 rootfs（root=/dev/mmcblk0p8），与社区 9 分区表不同
> 生成日期：2026-11-06。与产物严格对应：只写 p2 / p6 / p8，**永不写 p1（hiboot）**。

---

## 1. 这套系统是什么

| 组件 | 内容 |
|---|---|
| 内核 | 主线 Linux 6.3-rc5 + hi3798mv100 移植 + 本仓库补丁（tsensor / rtl8xxxu WiFi / simplefb 预留 / ext4-f2fs-btrfs-xfs-ntfs3-exfat 全内置） |
| 用户空间 | Debian 12 bookworm armhf（debootstrap），SSH 默认开启 |
| 网络 | eth0 与 WiFi（RTL8188FU）都是 DHCP；WiFi 用 ec6108-wifi 配 |
| 登录 | ssh root@<ip>，密码 ec6108v9c（**首次登录立刻改**）；telnet 23 端口备用 |
| 串口 | ttyAMA0 115200（有串口线时可用；本机目前无串口硬件） |

### eMMC 分区表（社区 9 分区，与本方案一致）

    blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),20M(kernel),64M(busybox),512M(backup),-(ubuntu)

| 分区 | 大小 | 内容 | 本包是否写 |
|---|---|---|---|
| p1 boot | 1M | hiboot | ★ 永不写 |
| p2 bootargs | 1M | 运行环境 env | 写 |
| p3 baseparam | 4M | 海思出厂参数 | 不写 |
| p4 pqparam | 4M | 画质参数 | 不写 |
| p5 logo | 4M | 开机 logo | 不写 |
| p6 kernel | 20M | 内核 uImage | 写 |
| p7 busybox | 64M | 社区救援系统 | 不写（社区两级接力已弃用） |
| p8 debian | 剩余 | rootfs | 写（Debian，含被回收的 512M backup） |

### 刷机包 U 盘结构与写入动作

    U盘根/
      bootargs.bin            ← hiboot 的"刷机脚本"（CRC32 env）
      mv100/
        hi_kernel.bin         → p6  (LBA 0x7000,   mmc write)
        bootargs.bin          → p2  (LBA 0x800,    mmc write)
        debian-root.ext4      → p8  (LBA 0x31000,  mmc write.ext4sp, 1GiB Android sparse)
        README.txt
      README.txt / SHA256SUMS.txt

hiboot 执行的 bootcmd 序列（已内置，无需手动操作）：

    run flashkernel   → fatload usb 0 0x1000000 mv100/hi_kernel.bin;   mmc write 0 0x1000000 0x7000 <扇区数>
    run flashrootfs   → fatload usb 0 0x1000000 mv100/debian-root.ext4; mmc write.ext4sp 0 0x1000000 0x31000 0x200000
    run flashbootargs → 校验 mv100/bootargs.bin CRC32 后写 p2
    reset

---

## 2. 刷机前必读

1. **p9 会被整个覆盖**。盒子现在是社区 Ubuntu（hinas），上面 /opt/alist、tailscale、各种配置刷完就没了。要保留的东西先在社区系统里备份出来（scp 到电脑或 U 盘）。
2. **p1 hiboot 永远不写**，所以 U 盘救援通道始终保留，理论上不会因此变砖。
3. **分区表与社区不同**：原 512M backup（p8）已回收并入 rootfs，rootfs 现在是 mmcblk0p8、起始 LBA 0x31000（约 7.9G 可用）。想回社区 Ubuntu 直接用社区 U 盘包重刷即可（它会重写自己的 p2/p7/p8/p9，自洽）。
4. p8 里原有的社区 recoverybox 救援系统会被覆盖——不影响 U 盘刷机救援（走 hiboot+U盘，与 p8 无关）。
5. 唯一需要物理操作的一步：**短接触发点**（和当年刷社区 Ubuntu 完全一样的操作）。
6. WiFi 驱动（rtl8xxxu）是首次真机验证，**先保持网线插着**，SSH 进去验证一切正常后再换 WiFi。

---

## 3. 准备 U 盘

1. 准备一个普通 U 盘（≥1GB 就够），**MBR 分区表 + FAT32**，单个主分区。
   - macOS 磁盘工具：抹掉 → 格式选"MS-DOS(FAT)"（默认 MBR）。
   - 不要 GPT、不要 exFAT、不要 NTFS，hiboot 的 fatload 只认 FAT32/MBR。
   - 个别大容量 U 盘（>64GB）hiboot 兼容性差，优先用 8~32GB 的。
2. 从 Release 下载 mv100-mdmo1g-debian-usb-flash-<时间戳>.zip，解压到 U 盘**根目录**，U 盘上应看到：

        bootargs.bin
        mv100/hi_kernel.bin
        mv100/bootargs.bin
        mv100/debian-root.ext4
        mv100/README.txt
        README.txt
        SHA256SUMS.txt

3. （可选校验）本机核对校验和：

        shasum -a 256 bootargs.bin mv100/*   # 与 SHA256SUMS.txt 比对

---

## 4. 刷机步骤

1. 盒子**断电**（拔电源）。
2. 插入 U 盘。
3. **短接触发点**（与刷社区 Ubuntu 时相同的两个触点/焊盘），保持短接状态下**上电**。
4. hiboot 自动执行：读 U 盘 → 写 p6（几秒）→ 写 p9（约 20~60 秒，看 U 盘速度）→ 写 p2 → 自动重启。
   全程大约 1 分钟，期间 HDMI 可能黑屏/花屏，正常。
5. 看到盒子重启后**拔掉 U 盘**（不拔也行，但建议拔掉避免再次误触发）。
6. 断电重启一次，正常开机（不短接）。

> 判断刷没刷成功：p6/p2 是秒级写入，p9 的 1GiB sparse 写入明显更久。如果上电后几秒就自动重启，多半是 U 盘没被识别——换个 USB 口/U 盘重来。

---

## 5. 首次启动与登录

1. 网线插路由器（DHCP）。开机约 30~60 秒后系统就绪。
2. 找到 IP：路由器后台 DHCP 列表；或电脑上扫网段 nmap -sn 192.168.3.0/24（按你的网段改）。
3. 登录：

        ssh root@<盒子IP>          # 密码 ec6108v9c
        # 备用: telnet <盒子IP>

4. **立刻改密码**：passwd
5. 首次开机自动做的事（systemd 服务）：
   - resize-rootfs.service：把 p9 从 1GiB 扩展到剩余全部 eMMC 空间（一次性）；
   - SSH host key 自动生成；ttyAMA0 getty 已配置。

---

## 5.5 内核命令行与内存是怎么来的（重要）

我们的内核用 `CONFIG_ARM_APPENDED_DTB`（DTB 追加在 zImage 后面）启动，这种方式下
**DTB 里的 /chosen/bootargs 会完全覆盖引导程序传来的命令行**，所以命令行必须完整写在
DTB 里（`configs/partition-layout.env` 是唯一数据源，内核构建和刷机包脚本共用）：

    model=mv100 clk_ignore_unused console=ttyAMA0,115200 root=mmcblk0p8     rootfstype=ext4 rootwait rw blkdevparts=... mem=1G

两个关键项：

- **mem=1G**：上游板级 DTS 没有 /memory 节点，而 DTB 启动时内核不会再用 ATAGS 的
  mem=，没有这一项内核会认为整机 0 字节内存直接 panic。补丁已同时加入
  /memory@0（reg = <0 0x40000000>），两条路径一致。DDR 容量不同的机型要改
  `configs/partition-layout.env` 的 MEM_SIZE / MEM_SIZE_STR。
- **clk_ignore_unused**：6.x 的 crg-hi3798 时钟驱动默认开启，内核启动末期会把
  "没人认领"的时钟关掉——VO/HDMI/VDP 时钟正是这样被关的，表现就是黑屏。
  这一项禁止内核动任何时钟，hiboot 留下的显示状态原样保留。

## 6. 刷后验证清单

    uname -a                       # Linux ... 6.3.0-rc5 ... armv7l
    cat /etc/os-release            # Debian GNU/Linux 12 (bookworm)
    ip -brief addr                 # eth0 有 DHCP 地址
    lsblk                          # mmcblk0p8 已扩容 (~7.9G)
    cat /sys/class/thermal/thermal_zone0/temp   # 毫度, 63000 左右 = 63°C（tsensor 补丁生效）
    ec6108-temp                    # 人性化读温度
    lsmod | grep rtl8xxxu          # WiFi 驱动
    ec6108-wifi <SSID> <密码>      # 配 WiFi, 之后可拔网线（先确认新 IP!）
    lsusb                          # 0bda:f179 RTL8188FU
    df -h                          # / 有几十 GB 可用

**HDMI 显示原理与点亮步骤**（重要）：

社区 Ubuntu 显示图片靠的是 4.4 内核里整套海思 hifb/VO/HDMI 私有驱动（主动驱动显示）。
我们的 6.x 主线内核没有这套东西，但 **hiboot 已经把 HDMI/VO/显示时钟全部配好并在持续扫描输出**，
只要内核不去动它，画面就一直挂着。已做的保障：

1. bootargs 加了 **clk_ignore_unused** —— 6.x 的 crg 时钟驱动（默认启用）否则会在启动末期
   关掉"没人认领"的 VO/HDMI/VDP 时钟导致黑屏；加了之后内核不碰任何时钟。
2. hiboot 的 logo framebuffer 是运行时从预留内存动态分配的（读 SDK 源码确认，
   没有固定地址），但 VO 层地址寄存器里存的就是它 —— 刷完 6.x 后：

       ec6108-fbprobe      # 扫描 VO 寄存器区 0xF9000000-0xF90FFFFF + HDMI 0xF8CE0000
                           # 找 "FB-like" 行 (0x3C-0x40 段 DDR 地址) = framebuffer 物理地址

3. 把 fbprobe 输出发回来 → 填进 CI 的 fb_base 参数重出包 → simplefb + fbcon 生效，
   HDMI 上有文字控制台。像素格式已从 SDK 源码确认：ARGB8888，stride=7680（1080p）。
   fbprobe 每页在子进程里读（未映射的寄存器页会 SIGBUS，不能让整个扫描死掉），
   输出里 `FB-like reg` 后面就是候选地址，`fb 0x…` 那一行是候选地址的实际内容。
4. 内核更新用 dd（见 §7），不用再刷 U 盘。

---

## 7. 日常更新内核（不需要 U 盘）

刷完一次后，内核可以直接从运行中的系统更新：

    # 在盒子上
    wget https://github.com/idealisan/ec6108v9c-debian/releases/latest/download/hi_kernel.bin
    dd if=hi_kernel.bin of=/dev/mmcblk0p6 bs=512 conv=fsync
    reboot

hi_kernel.bin 必须小于 20MiB（p6 上限），reboot 前确保 dd 成功无报错。
rootfs 更新用 apt；整包更新才需要重新 U 盘刷机。

---

## 8. 故障排查与救援

| 症状 | 处理 |
|---|---|
| 刷机时毫无反应 | U 盘格式/结构不对（须 MBR+FAT32，文件在根目录）；换 U 盘或 USB 口；确认短接点在**上电前**就已短接 |
| 刷完不启动、HDMI 无显示 | p6 内核问题概率大，等 SSH：若网络通说明 rootfs 正常，只是显示问题；网络也不通 → 走救援 |
| SSH 连不上 | 查路由器 DHCP；试 telnet 23；确认网线插好。都不通 → 救援 |
| 系统起不来 / 想回社区 Ubuntu | 用**社区 Ubuntu 的 U 盘刷机包**重复 §4，会覆盖 p9 回到社区系统（它会写入自己的 p2 环境变量，自洽；p1/p3/p4/p5/p7 保留） |
| 温度读数异常 | tsensor 读数用 SDK 公式，若为负/异常发 dmesg 回来分析 |
| eMMC 写坏 | p8 (512M backup) 未动，社区救援链（p7+p8）理论可用；极端情况重刷 |

**救援底线**：p1（hiboot）从未被本方案写过，只要 hiboot 活着，U 盘刷机通道永远可用——这是"不会变砖"的保证。

---

## 8.5 刷机前先跑 QEMU 验证（本机 / CI 同一脚本）

刷真机之前，先用 `scripts/qemu-local-test.sh` 在 QEMU 的 ARM virt 机器上把
**我们的 Debian rootfs** 启动一遍并验证 SSH。脚本本机和 CI 共用：

    # 本机 (macOS)
    CPIO=/opt/homebrew/opt/cpio/bin/cpio \
    ROOTFS_TAR=build/qemu/rootfs.tar.gz \
      bash scripts/qemu-local-test.sh

    # CI 里传的是 dist/debian-rootfs-armhf-bookworm.tar.gz，逻辑完全相同

原理与坑（都已固化在脚本里）：

- Debian 的 *installer* netboot initrd 会进安装器界面，内核包又不带 initrd.img，
  所以**把 rootfs 本身做成 newc cpio initramfs**（root=/dev/ram0），不需要磁盘镜像，
  也绕开 macOS 没有 mke2fs 的问题。
- initramfs 里必须有 `/init`（软链到 sbin/init），否则内核坚持挂载 root= 块设备并 panic。
- Debian 把 virtio_net / virtio_mmio / net_failover / failover 编成模块，
  用一个 systemd 单元按序 insmod；rootfs 必须装 `kmod` 才有 insmod。
- 解包 rootfs 时排除 `/dev/*` 设备节点（非 root 主机无法 mknod，systemd 会自己挂 devtmpfs）。
- 包索引解析不能写 `curl | gunzip | awk ... exit`：awk 提前退出会断管道，
  curl 报 (23)；改成下载成文件后用 python 解析。

通过标准：`== SSH reachable` + guest checks 里 Debian 12 armhf、eth0 有 DHCP 地址、
`systemctl is-active ssh` 为 active。2026-11-07 本机与 CI 双双通过。

注意：QEMU 验证的是**用户空间**（systemd / 网络 / SSH / 工具链），
SoC 专属驱动（HDMI、Tsensor、WiFi、eMMC）只能在真机上验。

---

## 9. 已知未验证项（诚实清单）

- rtl8xxxu 驱动在 RTL8188FU 上的实际稳定性（代码核对过，未真机验证；不行可回退 vendor 驱动）
- Tsensor 读数精度（公式来自 SDK 源码，未标定）
- HDMI fbcon（等 fbprobe 结果，见 §6）
- 首次启动 resize2fs 的一次性扩容
- 串口引导日志我们无法读取（无串口硬件）；一切异常靠 SSH/网络侧观察

---

## 10. 一页速查

    [准备] U盘 MBR+FAT32 → 解压 zip 到根目录
    [刷机] 断电 → 插U盘 → 短接触点 → 上电 → 等~1分钟自动重启 → 拔U盘 → 断电重开
    [登录] ssh root@<IP>  密码 ec6108v9c → passwd 改密码
    [验证] uname -a; ec6108-temp; ec6108-wifi <SSID> <密码>; ec6108-fbprobe
    [更新] dd hi_kernel.bin of=/dev/mmcblk0p6 → reboot
    [救援] 社区 Ubuntu U盘包重刷（同方法）
