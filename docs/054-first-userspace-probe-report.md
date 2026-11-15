# 054 — 首次 userspace 基线探测报告

> 目的：记录 2026-11-15 对**首个成功进入 TTY 登录提示**的版本所做的在线探测与
> 探索，供后续跟踪、复现与修正。本文只记录事实、证据链与已落地/待落地动作，
> 不把"推测"写成"结论"。

## 0. 摘要与里程碑

| 项 | 值 |
|---|---|
| release | `build-20261115T031956Z` |
| CI run | `43669116315`（全绿：rootfs 6m57s / kernel 35m55s / qemu 1m12s / package 1m6s） |
| 内核 | `6.3.0-rc5+` `armv7l` `SMP` |
| 发行版 | Debian 12 (bookworm) armhf |
| 探测方式 | 局域网 SSH（`192.168.3.102`），开发机本地 HTTP 代理经 SSH `-R` 转发 |
| 里程碑 | **L2 达成**：rootfs 挂载成功、systemd `running`、0 failed unit、以太网 DHCP + 互联网、`fbcon/VT` 接管显示、TTY 登录提示出现 |

**当前版本定位**：基础成功版，适合作为探测基线。已确认的内核侧能力基本齐备，
主要缺口集中在**显存保留**、**时钟/DNS/网络出口**、**用户态工具**三处，详见 §9 待办。

---

## 1. 基线快照（实测）

- `/proc/cmdline`：
  `root=/dev/mmcblk0p8 rootwait rootwait_timeout=30 rw ... mem=1G`（`rootwait` 修复已生效）
- `systemctl is-system-running` = `running`；`systemctl --failed` = 0
- 内存 `988Mi` total / `~138Mi` used；无 swap
- 根：`/dev/mmcblk0p8` ext4，6.7G，首启 `resize2fs` 已从 98304 → 1883648 blocks
- eMMC `008G30` 7.28 GiB，8 分区 `p1..p8`（`p8=debian`，`blkdevparts` 生效）
- 网络：`eth0 192.168.3.102/24`，网关 `192.168.3.38`，`hisi-femac` 100Mbps/Full
- USB：`RTL8188FTV 0bda:f179`（WiFi）、键盘、U 盘、4 个 root hub
- 显示：`fb0 hi3798vd 1920x1079@0x3f6ce000 pitch=7680`，`native_tty=1`，fbcon/VT 接管

---

## 2. 网络连通性：三层分离的关键发现

用户报告"能 ICMP 到网关、能连互联网"，但 `apt` 完全装不上包。实测是三层各自独立：

| 层 | 结果 | 说明 |
|---|---|---|
| ICMP（L3） | 通 | `223.5.5.5` / `119.29.29.29` 均 0% 丢包，~9ms |
| DNS | **失败** | 见 §2.1 |
| TCP/80/443 | **被拦** | 见 §2.2 |

### 2.1 DNS：stub 存在但无监听者

`/etc/resolv.conf` 是 `nameserver 127.0.0.53` 的 systemd stub 内容，但：
- `resolvectl` 不存在（包未装全）
- `systemctl is-active systemd-resolved` = `inactive`
- `/etc/resolv.conf` **不是**符号链接（`readlink -f` 指向自身）

→ 有 stub 地址、没有 stub 服务，`getent hosts deb.debian.org` 必然失败。

**临时修复（已做）**：写静态 `/etc/resolv.conf`，指向 DHCP 下发的网关 DNS
`192.168.3.38` + 公共 DNS 兜底，解析立即恢复。

**根治建议**：rootfs 里启用 `systemd-resolved`（或明确改用静态 resolv.conf + 关闭
stub 语义），二者只能选一，不能留"stub 文件 + 无服务"这种中间态。

### 2.2 TCP 出口：只有 ICMP 能出

`curl` 对 `deb.debian.org`、清华/阿里/中科大镜像、`www.baidu.com` 全部 `000`
（连 `https://` 也不通），但域名解析已正常、ICMP 正常 —— 说明是 **TCP 出口被网络策略拦截**，
不是盒子协议栈问题。

**打通方式（已验证）**：开发机本地 HTTP 代理只监听 `127.0.0.1:10808`，且开发机与盒子
不在同一网段，盒子无法直连。用 SSH 反向转发把代理带进盒子：

```
ssh -R 11080:127.0.0.1:10808 root@<BOX_LAN_IP>
# 盒子侧
export http_proxy=http://127.0.0.1:11080 https_proxy=http://127.0.0.1:11080
```

`curl -x http://127.0.0.1:11080 .../InRelease` 返回 `200`，通道可用。
`apt-get update` 经此通道成功拿到 14.9 MB 索引。

### 2.3 时钟：无 RTC、无 NTP，落后约 200 天

```
校准前: Mon Apr 27 20:12:07 UTC 2026
校准后: Sun Nov 15 03:53:56 UTC 2026
RTC time: n/a        # 硬件无 RTC
System clock synchronized: no
NTP service: n/a
```

apt 因此报 `Release file ... is not valid yet (invalid for another 74d ...)`，
**即使网络通了也拒绝安装**。这是第三个独立阻断点。

**临时修复（已做）**：`date -s @<epoch>` 校准。
**根治建议**：启用 `systemd-timesyncd`（或首次启动校时脚本）；无 RTC 的板子每次
冷启动都会回到固定旧时间，必须依赖 NTP。

> 小结：apt 失败是 **DNS + TCP 出口 + 时钟** 三个独立问题叠加，单独修任何一个都不够。

---

## 3. apt 补包与 dpkg 异常

**结果**：`rfkill`、`dig`/`nslookup`（dnsutils）装上了；
`iw`、`nc`（netcat-openbsd）、`vim`、`git` 未装上。

**异常**（多次复现）：
```
dpkg-deb: lzma error: compressed data is corrupt
dpkg-deb: error: ... is not a Debian format archive
E: Sub-process /usr/bin/dpkg received a segmentation fault.
apt exit 139
```

`dpkg --configure -a` 已修复 `libc-bin` trigger 挂起，`dpkg --audit` 仅剩该 trigger。
但这些**下载包本身损坏**的现象不能用网络解释（apt 索引校验是通过的），
指向内存被踩 —— 见 §4。

---

## 4. 花屏（彩色噪点 / 彩色条带）：根因与修复 ★

### 4.1 现象与证据

用户在屏幕上看到"乱七八糟的彩色小点""像在绘制彩色条带以及随机噪点"。
同一时段出现 §3 的 dpkg 数据损坏。

实测：
```
/proc/iomem:
  00000000-2fffffff : System RAM
  30100000-3fffffff : System RAM      # 一直覆盖到 1 GiB 顶端

dmesg:
  OF: reserved mem: 0x30000000..0x300fffff  ramoops@30000000  (仅 1 MiB, no-map)
  hi3798-vd: NATIVE fbdev fb0 registered 1920x1079@0x3f6ce000 (8,286,720 B)

/proc/device-tree/reserved-memory/ 下只有 ramoops@30000000
```

→ `fb0` 位于 `0x3f6ce000`（≈1015 MiB），一帧延伸到 `0x3feb5200`，
**完全落在内核认为可分配的普通 RAM 里**。hiboot 留下的这块显存，VO 硬件仍在
持续扫描；内核把它当普通页分配出去（apt 大批量解包时尤其容易命中），
于是屏幕显示随机数据 = 彩色噪点/条带，同时被写入的包数据反过来损坏 = dpkg 崩溃。

这与 `docs/053 §6` 早先预判的"显存保留隐患"完全一致，现由真机证据坐实。

### 4.2 原厂怎么做（不需要我们自己探索）

**原厂 Android / 社区刷机包 p2 的 `bootargs_1G`**：
```
mem=1G mmz=ddr,0,0,48M vmalloc=500M     # 原厂 p2 / 9 分区 env
mem=1G mmz=ddr,0,0,256M vmalloc=500M    # 社区刷机包 mv100/bootargs.bin
```

`mmz` = HiSilicon 私有的 **Media Memory Zone**：vendor 内核的 `hi_mmz` 驱动解析
该参数，把 DDR 高端一块内存划给显示/多媒体，**内核不再把它当普通 RAM 分配**。
原厂 Android 的 `boot.img` cmdline 本身不带 `mmz`，由 hiboot 按 DDR 容量从
`bootargs_<size>` 变量拼接 —— 这就是"最正确的用法"。

> 注：按用户确认，**社区 4.4 系统没有实现显示功能**，其 `mmz=256M` 是给解码器用的，
> 不作为显存保留的参照。显存语义以原厂 Android 为准。

**主线 6.3 没有 `hi_mmz` 驱动**，`mmz=` 会被当作未知参数忽略，于是 `mem=1G`
把整块 1 GiB（含显存）交给伙伴系统 —— 这就是 bug 的全部来源。

### 4.3 主线等价修复（已落地，待真机验证）

标准等价物是 `reserved-memory`，但**关键细节：不能带 `no-map`**。

| 方式 | 内核行为 | 对本项目 |
|---|---|---|
| `reserved-memory` + `no-map` | `memblock_mark_nomap`，区域**移出** System RAM | ✗ 显示驱动的 `memremap(MEMREMAP_WB)` 会失败，绿带/console 丢失 |
| `reserved-memory` **不带** `no-map` | 仅 `memblock_reserve`，区域**仍是** System RAM 但不再分配 | ✓ 内核不踩显存，`memremap(WB)` 仍可用 |

已修改 `scripts/apply-dts-placeholders.py`：在 `FB_BASE` 未设置（即 vendor-backport
路径）时，向唯一的 `reserved-memory` 容器注入一个显存保留节点，
**地址由 DDR 尺寸推导、不写死猜测的物理地址**（对齐原厂"高端划走"的语义）：

```
fb_reserve: framebuffer-reserved@3e000000 {
    reg = <0x3e000000 0x2000000>;   /* 顶端 32 MiB, 无 no-map */
};
/* + 原有 ramoops@30000000 (no-map, 1 MiB) */
```

- 保留区 `0x3e000000–0x40000000`，覆盖 `fb0 0x3f6ce000–0x3feb5200` ✓
- 可用 `FB_RESERVE_SIZE` 环境变量调整
- `dtc -I dts -O dtb` 编译通过（本地最小 DTS 校验）
- `CONFIG_ARM_APPENDED_DTB` 下 `/chosen/bootargs` + `/memory@0` 仍是权威，无需改 cmdline

**待验证**：需刷入含此修复的新包，确认 (a) 花屏消失 (b) TTY 文字仍在
(c) apt 大批量解包不再 segfault。

---

## 5. WiFi

### 5.1 硬件与驱动（已通）

```
usb 3-2: RTL8188FU rev B (SMIC) ... WiFi=1
usb 3-2: RTL8188FU MAC: 84:21:f1:ed:f5:83
usb 3-2: rtl8xxxu: Loading firmware rtlwifi/rtl8188fufw.bin
usb 3-2: Firmware revision 4.0 (signature 0x88f1)     # 固件内置内核成功
usbcore: registered new interface driver rtl8xxxu
/sys/class/net/: eth0, lo, wlan0        # net.ifnames=0 生效, 是 wlan0 不是 wlx<mac>
cfg80211: failed to load regulatory.db   # 见下
```

内核 `CONFIG_RTL8XXXU=y` 是**编进内核**（非 .ko），`lsmod | grep rtl8xxxu` 无输出属正常。
`CONFIG_EXTRA_FIRMWARE` 把 `rtl8188fufw.bin` 内置进 vmlinux，解决了早期无 initramfs
时 `/lib/firmware` 不可用的问题 —— 已验证生效。

`cfg80211: failed to load regulatory.db` 是**早期**请求（rootfs 尚未挂载）失败；
`wireless-regdb` 包已装、`/lib/firmware/regulatory.db` 文件确实存在，属非致命，
可在 userspace 用 `iw reg set` / 重新触发加载处理。

### 5.2 工具现状与已修复项

- 已有：`iwconfig`/`iwlist`（wireless-tools）、`wpa_supplicant`/`wpa_passphrase`/`wpa_cli`、
  `nano`、`tcpdump`、`ethtool`、`lsusb`、`htop`、`curl`、`wget`、`python3`、`strace`、
  `lsof`、`i2cdetect`、`sensors`、`fbset`、`tmux`、`minicom`、`ip`、`systemctl`
- 缺失：`iw`、`rfkill`、`dig`/`nslookup`、`nc`、`vim`、`git`（`nmcli` 见 §5.3）
- 已在 `build-rootfs.sh` 的 PACKAGES 补齐：`iw rfkill dnsutils netcat-openbsd`

**`rootfs/usr/local/bin/ec6108-wifi` 已修**：
- 原来写死 `IF=wlx8421f1edf583`，但 `net.ifnames=0` 下实际是 `wlan0` → 必然失败
- 原来用 `ifup`，但 `networking.service` 被 mask、接口由 `systemd-networkd` 管 → 必然失败
- 现在：运行时用 `iw dev` / `/sys/class/net/wl*` 探测接口，
  `wpa_passphrase` 写配置，`wpa_supplicant -B` 只负责 WPA 握手，DHCP 交给
  `20-wlan.network`；不杀进程（避免清理类动作）
- `scripts/build-rootfs.sh` 的 `/etc/network/interfaces` 同步改成 `wlan0`

### 5.3 `nmcli` 到底能不能用？—— 能，但需要显式分工

之前判断"不能装 NetworkManager"过于绝对，修正如下：

NetworkManager 和 systemd-networkd **可以共存**，只要明确划分接口，
否则两者同时抢 `eth0`/`wlan0` 的 DHCP 和配置，正是"弄断以太网"的风险来源。
可行配置：

```
# /etc/NetworkManager/conf.d/10-unmanaged-eth.conf
[keyfile]
unmanaged-devices=interface-name:eth0      # eth0 永远归 systemd-networkd
```

同时让 `systemd-networkd` 不再匹配无线接口（改 `20-wlan.network` 的 `[Match]`
或将其 `Name=wl*` 收窄），把 `wlan0` 完整交给 NM。这样：

- `eth0`：networkd 管 → 现有以太网 / SSH **不受影响**
- `wlan0`：NM 管 → `nmcli dev wifi list` / `nmcli dev wifi connect <SSID> password <PWD>` 可用

代价：NM 会拉入 dbus/policykit 等依赖，rootfs 与启动时间都会增加；对 988 MiB 内存
的盒子是可感知的开销。**建议**：这版作为探测基线保持现状（`iw` + `wpa_supplicant`
已够用），把 `network-manager` 作为可选增强放进后续版本，不要在当前基线上在线硬装。

---

## 6. 文件系统 / 网络存储网关能力（用户规划：双 USB 挂网络存储）

### 6.1 NTFS：**不需要升级内核** ✓

主线内核自 **5.15** 起合入 Paragon 的 `ntfs3`（内核原生、支持读写），
6.3 的 `fs/ntfs3/` 完整存在。本项目 config fragment 已启用：

```
CONFIG_NTFS3_FS=y        # CI build log 实测确认生效
```

所以 Linux 6.3 主线**已有 NTFS 内置支持**，无需升级内核、无需 `ntfs-3g`（FUSE）。

### 6.1.1 实测坑：`mount` 不带 `-t` 会失败（名字不匹配）

真机实测（2026-11-15，接一块 931.5G "Elements SE" NTFS 移动硬盘）：

```
# mount /dev/sdb1 /mnt/usb2
mount: /mnt/usb2: unknown filesystem type 'ntfs'.

cat /proc/filesystems | grep -i ntfs   ->  ntfs3      # 内核注册名是 ntfs3
blkid /dev/sdb1                        ->  TYPE="ntfs" # libblkid 返回 ntfs
find /lib/modules -iname '*ntfs*'      ->  (空)        # =y 内建, 非模块
```

**根因**：内核 `ntfs3` 驱动注册的文件系统名是 `ntfs3`，而 `libblkid` 探测返回
`ntfs`；`mount` 不带 `-t` 时按 blkid 的名字去调内核，找不到 `ntfs` 便报错。
**不是内核缺驱动**，也不是 `CONFIG_NTFS3_FS` 没生效。

**解决**：显式指定类型即可（实测 `MOUNT_EXIT=0`，`rw`，931.5G 正常列出内容）：

```
mount -t ntfs3 /dev/sdb1 /mnt/usb2
```

**一劳永逸的做法**（三选一，避免每台机器都手动加 `-t`）：
1. `/etc/filesystems` 里把 `ntfs3` 放在 `ntfs` 之前，`mount` 探测时会优先尝试；
2. 在 `/etc/fstab` 明确写 `ntfs3`（用 UUID，不写 `/dev/sdX`）：
   `UUID=<ntfs-uuid> /mnt/usb2 ntfs3 defaults,uid=0,gid=0,iocharset=utf8,nofail 0 0`；
3. 用 udev/systemd-mount 自动挂载时，在规则里指定 `fstype=ntfs3`。

> 注意：Debian 的 `ntfs-3g` 包会在 `/sbin/mount.ntfs` 放一个 helper，使不带 `-t`
> 的挂载也能走 FUSE；本镜像没有装它（也不需要），所以必须显式 `-t ntfs3`。
> 若后续为了兼容旧脚本要装 `ntfs-3g`，反而会用 FUSE 覆盖内核原生 ntfs3，
> 性能和稳定性都更差 —— 建议不装，统一用 `-t ntfs3`。

**顺带**：dmesg 里 `FAT-fs (sda): Directory bread(block N) failed` 是刷机用的那个
U 盘（FAT32）的读错误，与这块 NTFS 移动硬盘无关；两者不要混淆。

### 6.2 中文文件名不能正确显示：locale 未生成（非缺 UTF-8 支持） ★

真机实测（2026-11-15，NTFS 盘上有 `猫和老鼠.fcpbundle` / `第一项完整病历` 等）：

| 层 | 结论 |
|---|---|
| 文件名与内核 NLS | **正常**。`os.listdir()` 得到 `e78cab...`（"猫"的标准 UTF-8 字节），挂载带 `iocharset=utf8`，`/proc/filesystems` 有 `ntfs3`；`CONFIG_NLS_UTF8` / `CONFIG_NLS_DEFAULT="utf8"` 均已启用 |
| userspace locale | **坏**。`locale` 报 `Cannot set LC_CTYPE to default locale: No such file or directory`；`LANG=en_US.UTF-8`，但 `locale -a` 只有 `C / C.utf8 / POSIX` |
| 根因 | `build-rootfs.sh` 装了 `locales` 包却**从未 `locale-gen`**，且 shrink 步骤删掉 `/usr/share/locale`；sshd 的 `AcceptEnv LANG LC_*` 把客户端的 `LANG=en_US.UTF-8` 带进来，指向一个不存在的 locale → glibc 退回 C/ASCII 行为（中文被 quote 成 `\xxx`、排序错乱、程序报错） |
|  aggravating factor | 在线尝试 `locale-gen en_US.UTF-8` 直接 **Segmentation fault** —— 与 §4 的显存未保留同源（内存密集操作），刷入含显存保留的包后应消失 |

**关键认识**：`C.UTF-8` 是 glibc ≥ 2.35 内建的（bookworm 为 2.36），**不需要任何
locale 数据文件**，因此不受 shrink 影响、也不需要 `locale-gen`。验证：
`LANG=C.UTF-8 ls -1 /mnt/usb2` 正确输出 `猫和老鼠.fcpbundle`、`第一项完整病历`、
`第二项XML格式`。

**已在线修复**（`/etc/default/locale` 写 `LANG=C.UTF-8`，注释掉 sshd 的
`AcceptEnv LANG LC_*` 以防客户端覆盖，`systemctl reload ssh`）：
`locale` 不再报错，中文文件名正常显示。

**已固化到 `scripts/build-rootfs.sh`**（下版刷机自带，无需再手工改）：
1. SSH 段里注释 `AcceptEnv LANG LC_*`
2. `tee /etc/default/locale` 写入 `LANG=C.UTF-8`
3. shrink 注释同步更正（原注释说"The C locale..."，容易让人误以为已处理 UTF-8）

**关于 TTY 控制台字体**：fbcon 用的是 8x16 点阵字体（`console-setup`/`kbd` 已装，
`/usr/share/consolefonts/` 存在），这类字体最多 256/512 个字形，**不含 CJK 汉字**，
所以 HDMI 本地 TTY 上中文仍会显示成方块/问号，这是内核 console 字体的固有限制，
与 locale 无关。SSH/串口终端由终端模拟器渲染 UTF-8，不受此限。若确需本地 TTY
显示中文，需要额外加载 CJK console 字体（`setfont` + unifont 之类），本项目暂不做。

> 注：之前判断"NTFS 不用升级内核"依然成立；本节的"中文显示"完全是 userspace
> locale 配置问题，与内核文件系统/编码支持无关，两件事不要混为一谈。

## 6.3 CI 构建失败记录：`mke2fs -d` 镜像装不下 rootfs（已修）

run `43675288224` 的 `package` job 失败（kernel/rootfs/qemu 均通过）：

```
__populate_fs: Could not allocate block in ext2 filesystem while writing
               file "base-passwd.templates"
mke2fs: Could not allocate block in ext2 filesystem while populating file system
```

**根因**：`make-community-flash-package.sh` 把 ext4 镜像尺寸写死为
`IMG_SIZE_MB=384`（当初 payload ~240 MiB 够用）。§5.2 往 PACKAGES 加了
`iw rfkill dnsutils netcat-openbsd` 等基础工具后，CI 日志显示
`payload now: 287M`，`mke2fs -d` 还要额外装 inode/journal/保留块，384 MiB
被撑爆。**不是磁盘满、不是权限、也不是 rootfs 内容坏了。**

**修复**（已落地）：改为按实际 payload 动态计算，不再写死：
- 取 `du -sm "$WORK/root"`，给 50% 余量，向上取整到 32 MiB 边界
- 下限 384 MiB；上限 480 MiB（约束：p8 从 98 MiB 起，社区 p9 从 610 MiB 起，
  98 + IMG 必须留在这之下，刷机失败仍能回社区系统）
- 超过 480 直接 fail 并提示"精简 rootfs 或显式调整上限"，不静默产出坏包
- 仍支持 `IMG_SIZE_MB` 环境变量显式覆盖

验证：`287M -> 448M`（98+448=546 < 610）；`bash -n` 通过。
recovery 包复用同一 sparse 文件，其 manifest 里 p8 为 `S` 类型（bytes 忽略），
不受尺寸变化影响。

> 这个 run 触发于 locale 修复推送之前，因此其产物不含 §6.2 的 locale 修复。
> 修复镜像尺寸后基于最新 HEAD 重新触发的 release 才包含全部修复。

### 6.2 已启用的文件系统/存储能力（config fragment 实测）

| 类别 | 已启用 |
|---|---|
| 本地 FS | `EXT4_FS`, `F2FS_FS`, `BTRFS_FS`, `XFS_FS`, `SQUASHFS`(+XZ/ZSTD), `OVERLAY_FS`, `FUSE_FS`, `AUTOFS_FS`, `TMPFS` |
| Windows/移动盘 | `NTFS3_FS` **=y**, `EXFAT_FS`, `VFAT_FS`, `FAT_FS` |
| 网络 FS | `NFS_FS=y`, `CIFS=m`, `CIFS_XATTR`, `FS_ENCRYPTION`, `FS_VERITY` |
| USB 存储 | `USB_STORAGE=y`, `USB_UAS=y`, `SCSI`, `BLK_DEV_SD`, `BLK_DEV_LOOP` |
| NLS | `NLS_DEFAULT="utf8"`, `NLS_CODEPAGE_437`, `NLS_UTF8` |

结论：**作为网络存储网关的内核基础已经齐备**，NTFS/exFAT/FAT/ext4/btrfs/xfs/f2fs
都能直接挂载双 USB 外接盘。

### 6.3 仍建议补充（非阻塞）

- 内核：`UDF_FS`（DVD/蓝光镜像）、`HFSPLUS_FS`（Mac 格式移动盘）当前未见启用 → 可选加
- 用户态：`exfatprogs`、`btrfs-progs`、`xfsprogs`、`f2fs-tools`、`nfs-common`、
  `cifs-utils`、`samba`/`nfs-kernel-server`（若要做对外共享）、`ntfs-3g`（仅当需要
  NTFS 特定高级特性时，内核 ntfs3 一般已够）
- `CONFIG_CIFS=m` 是模块，需确认 `modules.tar.gz` 已正确装入 rootfs；
  `nfs` 若做服务端还需 `NFSD`（当前未见）

---

## 7. GPU / 媒体编解码

| 项 | 实测 | 结论 |
|---|---|---|
| GPU 节点 | `/sys/bus/platform/devices/f9200000.gpu` 存在；DTS `gpu@9200000 compatible="arm,mali-450","arm,mali-utgard"` | Mali-450 MP |
| `/dev/dri` | **不存在** | 无 DRM 渲染节点 |
| 已加载模块 | 只有 `drm` + `drm_panel_orientation_quirks`（`modprobe@drm.service` 拉起） | 无 GPU 驱动绑定 |
| 主线 `lima` | 源码 `drivers/gpu/drm/lima/` 存在（Mali-4xx UTgard 开源驱动） | **config 未启用** `CONFIG_DRM_LIMA` |
| V4L2 / media | 无 `/dev/video*`、`/dev/media*` | 无摄像头/编解码设备节点 |
| dmesg | 无 `mali`/`vpu`/`vdec`/`venc`/`h264`/`h265` 记录 | 硬件编解码未初始化 |

**对"解码估计也就 H264、H265 很难"的判断：基本正确，但更保守** ——
在主线 6.3 上目前**任何硬件编解码都没有**：HiSilicon 的 VDEC/VENC/OMX 是私有栈，
主线内核没有对应驱动，也没有 V4L2 M2M 节点。可用的是**纯软解**（ffmpeg/gstreamer），
在这颗 ~1 GHz 级 4 核 Cortex-A7 class CPU、988 MiB 内存上，1080p H.264 软解勉强，
H.265/HEVC 软解基本不现实。GPU 侧 `lima` 可考虑启用（OpenGL ES 2.0 级），
但它不提供视频硬解。

**建议**：既然规划用途是"网络存储网关 / 文件系统挂载"，GPU 与硬解不是必需项，
保持现状即可；若后续确实需要硬解，只能走 vendor 私有多媒体栈（工作量远大于
本轮主线方案），不应期待靠升级内核版本自动获得。

---

## 8. 本轮已落地的代码改动

| 文件 | 改动 | 目的 |
|---|---|---|
| `scripts/apply-dts-placeholders.py` | vendor-backport 路径注入顶端 32 MiB `reserved-memory`（无 `no-map`），地址由 DDR 尺寸推导 | **修花屏根因**（§4.3） |
| `scripts/build-rootfs.sh` | PACKAGES 加 `iw rfkill dnsutils netcat-openbsd`；`/etc/network/interfaces` 写死接口名改 `wlan0` | 基础网络工具内置、修 WiFi 配置 |
| `rootfs/usr/local/bin/ec6108-wifi` | 动态探测接口、改用 `wpa_supplicant`+networkd、去掉 `ifup`、不杀进程 | 修 WiFi 连接脚本 |
| `patches/vendor-display/hi3798mv100_vendor_display.c` | `BOOT_MARK_LINES` 240 → **24** | 绿带缩小到约 1/10，减少晃眼，保留排障可见性；文字区反而多约 14 行 |

（commit message 遵循仓库风格、无任何 AI Agent 追加信息 / trailer；
所有推送内容已检查不含本机绝对路径与用户名。）

---

## 9. 待办 / 跟踪清单（编号供后续引用）

| # | 优先级 | 事项 | 状态 |
|---|---|---|---|
| P0-1 | 高 | 刷入含 §4.3 显存保留的包，验证花屏消失、TTY 正常、apt 不再 segfault | **待真机验证** |
| P0-2 | 高 | 时钟：启用 `systemd-timesyncd` 或首启校时（无 RTC，冷启动必回旧时间） | 临时已校准，根治待做 |
| P1-1 | 中 | DNS：统一 `systemd-resolved` 或静态 resolv.conf，消除"stub 文件 + 无服务" | 临时已修，根治待做 |
| P1-2 | 中 | TCP 出口：确认是上游网关策略还是盒子网络配置；若长期受限，固化代理配置方案 | 已定位，待定性 |
| P1-3 | 中 | 把 `iw`/`nc`/`vim`/`git` 真正装进 rootfs（本轮在线安装受显存踩踏影响失败） | 已加 PACKAGES，待出包验证 |
| P1-4 | 中 | `regulatory.db` 早期加载失败：评估是否内置进 `CONFIG_EXTRA_FIRMWARE` | 已定位，非致命 |
| P2-1 | 低 | `nmcli`：按 §5.3 方案评估是否引入 NetworkManager | 待用户决定 |
| P2-2 | 低 | 文件系统：补 `UDF_FS`/`HFSPLUS_FS` + 用户态 fs 工具 + NFS/CIFS 服务端 | 内核基础已够 |
| P2-3 | 低 | GPU：评估启用 `CONFIG_DRM_LIMA`；硬解走私有栈另立项 | 非网关必需 |
| P2-4 | 低 | 绿带 24 行的真机观感确认 | 待反馈 |

---

## 10. 复现命令速查

```
# 基线
cat /proc/cmdline; systemctl is-system-running; systemctl --failed
cat /proc/iomem | grep -i "System RAM"; free -h
cat /proc/device-tree/reserved-memory/*/name 2>/dev/null

# 网络三层
getent hosts deb.debian.org
curl -s -o /dev/null -m 5 -w "%{http_code}\n" http://deb.debian.org/debian/dists/bookworm/InRelease
ping -c2 -W2 223.5.5.5
timedatectl status; date -u

# 经 SSH -R 代理装包
ssh -R 11080:127.0.0.1:10808 root@<BOX_LAN_IP>
export http_proxy=http://127.0.0.1:11080 https_proxy=http://127.0.0.1:11080
apt-get update && apt-get install -y --no-install-recommends iw rfkill dnsutils netcat-openbsd

# 显示 / 显存
dmesg | grep -iE "hi3798-vd|fb0|reserved mem"
cat /sys/class/graphics/fb0/name
ls /dev/dri /dev/video* /dev/media* 2>/dev/null

# WiFi
lsusb; iw dev; iw dev IFACE scan | grep -E 'SSID|signal|RSN'; rfkill list
iw reg get; dmesg | grep -iE "rtl8xxxu|firmware|cfg80211"

# 文件系统
grep -E "CONFIG_(NTFS3|EXFAT|VFAT|BTRFS|XFS|F2FS|UDF|HFSPLUS)_FS" /path/to/config
```

> 凭据、开发机地址与本机路径不写入本报告；仅保留复现所需的形式化占位符。
