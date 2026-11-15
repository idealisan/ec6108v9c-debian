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
| 探测方式 | 局域网 SSH（`<BOX_LAN_IP>`）；TCP 出口直连可用，无需代理（§2.2 已更正） |
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
- 网络：`eth0 <BOX_LAN_IP>/24`，网关 `<GW>`，`hisi-femac` 100Mbps/Full
- USB：`RTL8188FTV 0bda:f179`（WiFi）、键盘、U 盘、4 个 root hub
- 显示：`fb0 hi3798vd 1920x1079@0x3f6ce000 pitch=7680`，`native_tty=1`，fbcon/VT 接管

---

## 2. 网络连通性：三层分离的关键发现

用户报告"能 ICMP 到网关、能连互联网"，但 `apt` 完全装不上包。首轮实测曾误判为
"TCP 出口被拦"；第二轮在 DNS 与时钟修好后复测，**证实 TCP 直连完全可用**（见
§2.2 更正）。`apt` 失败其实只有 DNS + 时钟两个独立阻断点。

| 层 | 结果 | 说明 |
|---|---|---|
| ICMP（L3） | 通 | `223.5.5.5` / `119.29.29.29` 均 0% 丢包，~9ms |
| DNS | **首轮失败** | 见 §2.1；§11.5 已根治 |
| TCP/80/443 | **通（首轮误判）** | 见 §2.2 更正 |

### 2.1 DNS：stub 存在但无监听者

`/etc/resolv.conf` 是 `nameserver 127.0.0.53` 的 systemd stub 内容，但：
- `resolvectl` 不存在（包未装全）
- `systemctl is-active systemd-resolved` = `inactive`
- `/etc/resolv.conf` **不是**符号链接（`readlink -f` 指向自身）

→ 有 stub 地址、没有 stub 服务，`getent hosts deb.debian.org` 必然失败。

**临时修复（已做，但重刷会回退）**：写静态 `/etc/resolv.conf`，指向 DHCP 下发的
网关 DNS `<GW>` + 公共 DNS 兜底，解析立即恢复。

**根治**（§11.5，本轮已落地）：rootfs 内置静态兜底 `resolv.conf`，开机由
`ec6108-dns-init.service` 从 DHCP DNS 重建（网关优先 + 公共兜底）；不引入
`systemd-resolved`，彻底消除"stub 文件 + 无服务"的中间态。

### 2.2 TCP 出口：首轮误判"被拦"，第二轮证实直连可用 ★（更正）

首轮 `curl` 对 `deb.debian.org`、清华/阿里/中科大镜像、`www.baidu.com` 全部 `000`，
当时 DNS 与时钟均为坏状态，遂误判为"TCP 出口被网络策略拦截"，并用 SSH `-R` 把
开发机 HTTP 代理带进盒子（`curl -x ... 200`、apt 走该通道成功）作为临时绕行。

**第二轮复测（DNS §11.5 与时钟 §11.6 修好后）推翻该结论** —— 用户指出"明明刚用命令
下载了文件"，实测确认：

| 测试（无任何代理变量） | 结果 |
|---|---|
| `curl` 默认 → deb.debian.org / 清华 / 阿里 / 百度 | 全部 `code=200` |
| `curl -4` 同上 | 全部 `code=200` |
| `curl -6` | `code=000`（盒子只有 `fe80::` link-local IPv6，无全局 IPv6） |
| `apt-get update -qq` 直连 | `RC=0` |
| 直连下载 `Release` 文件 | `code=200, 149266 B` |
| `apt-get install fake-hwclock` 直连 | 成功（6.3 kB，无需代理） |

根因：DNS 会优先返回 AAAA（`2a04:4e42:99::644`），而盒子没有全局 IPv6，curl
卡在 IPv6 上超时；叠加当时 DNS/时钟故障，表现为"TCP 全不通"。
**结论：TCP/80/443 出口本来就是通的，不需要代理**。SSH `-R` 只是当时的临时绕行
手段，已从方案中移除；本节保留更正记录，避免后续再按错误结论排查。

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

**临时修复（已做，重刷会回退）**：`date -s @<epoch>` 校准。
**根治**（§11.6，本轮已落地）：Debian 标准的 RTC-less 三件套 —— `fake-hwclock`
（文件式软件 RTC，关机存 / 开机恢复）+ `/usr/lib/clock-epoch`（systemd 时间下限）
+ `systemd-timesyncd`（NTP 精校）。

> 小结（按 §2.2 更正）：apt 失败是 **DNS + 时钟** 两个独立问题叠加；
> TCP 出口本来就是通的，首轮属误判。

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

**修复历程（两次 40 分钟 CI 失败，值得记录）**：

1. 第一次尝试改成"按实际 payload 动态计算"（`du -sm "$WORK/root"`）。**引入了新
   bug**：rootfs 由 `sudo` 解压，`/root`、`/etc/ssl/private` 是 root-only，普通用户
   `du` 报 `Permission denied`，而脚本 `set -o pipefail` 让 `du | cut` 整条退出
   非 0 → job 直接挂。第二次 CI 因此又失败 29s。
2. 同时发现动态方案的系数/上限组合还有隐患：payload 已 287 MiB，但**打包阶段
   还会解压 `modules.tar.gz`**（实测压缩 22.7 MiB / 解压 70.7 MiB / 1925 个文件），
   实际 payload ≈ 358 MiB，很容易触发 fail-fast 上限 → 会埋第三次失败。
3. 最终采用**简单固定值 480 MiB**，去掉易错的动态计算：
   - 实测余量：`358 MiB payload → 480 MiB 镜像`，余 122 MiB 给 ext4 元数据
     （inode / journal / 5% reserved blocks），充足
   - 上限约束：p8 从 LBA `0x31000`（98 MiB）起；社区刷机法从同一 LBA 写
     `0x100000` 扇区（512 MiB，到 610 MiB）作为 Ubuntu 回退区。
     `98 + 480 = 578 < 610`，保住 32 MiB 余量，刷机失败仍可回退
   - 保留 `IMG_SIZE_MB` 环境变量覆盖；`bash -n` 通过

> 教训（写给后续）：不要用 `du` 去量 `sudo` 解压出来的 tree，除非也用 `sudo du`
> 且对 pipefail 做兜底；这个包里能静态确定的常量比"自适应"更可靠。
> recovery 包复用同一 sparse 文件，其 manifest 里 p8 为 `S` 类型（bytes 忽略），
> 不受尺寸变化影响。

**最终状态（2026-11-15 13:53）**：release **`build-20261115T054445Z`** 全绿发布
（CI run `43680457572`，含 §4.3 显存保留、§5.2 工具补齐/绿带缩小、§6.2 locale
修复、§6.1.1 NTFS 记录、§6.3 镜像尺寸修复等全部改动）。制品已下载到项目内
`TMP/ci-download/`，SHA256 全量 10/10 OK，并已只覆盖（不删除）装到 U 盘
`/Volumes/BOXBAK`：U 盘侧 SHA256 全量 OK、`hi_kernel.bin` 大小与 manifest 一致、
p1 fastboot 未写、顶层 `bootargs.bin` 的 recovery 刷机入口 CRC 正确、
sparse 镜像 480 MiB。**仍待真机刷入验证**：花屏是否消失、TTY 是否正常、
中文文件名是否正常、apt 是否不再 segfault（§9 P0-1 等）。

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

### 7.1 第二轮复测 +「用原厂安卓私有驱动/固件」可行性（用户建议）

第二轮真机（§11 同期）复测确认 §7 结论不变：无 `/dev/dri`、无
`/dev/video*`/`/dev/media*`、平台设备只有 `f9200000.gpu`、模块只有
`drm` + `drm_panel_orientation_quirks`、dmesg 无 `mali`/`vpu`/`vdec`/`venc`；
用户态无 `ffmpeg`/`gstreamer`/`mesa` 任何工具。CPU 为 4× ARMv7（NEON、VFPv4，
BogoMIPS 1959.93），1080p H.264 软解勉强、H.265 不现实 —— 与用户"解码估计也就
H264、H265 很难"的判断一致。

**主线 GPU 其实有一条现成的路（不需要原厂私有驱动）**：

| 项 | 状态 |
|---|---|
| 主线 6.3 `drivers/gpu/drm/lima/`（Mali-4xx UTgard 开源驱动） | **源码存在** |
| DTS `gpu@9200000` | 存在，`compatible="arm,mali-450","arm,mali-utgard"`、8 个中断带 `interrupt-names`、`clocks=<&crg HISTB_GPU_BUS_CLK/GP_CLK>`、`resets=<&crg 0xd4 4>`、`mali-supply`、8 档 OPP(150~500 MHz)；但 **`status="disabled"`** |
| config fragment | 只有 `CONFIG_FRAMEBUFFER_CONSOLE*`，**没有任何 DRM/LIMA/MEDIA 项** |

即驱动与硬件描述都齐，只差 ① DTS `status="okay"` ② 启用 `CONFIG_DRM` +
`CONFIG_DRM_LIMA`（及 CMA/DMA_CMA 依赖）③ 确认 crg clock/reset 驱动能提供 GPU
时钟 ④ 用户态 Mesa `lima_dri.so` + libdrm。一轮 CI 可验证，但 lima 只给
OpenGL ES 2.0 级 3D，**不提供视频硬解**。

**用户建议：利用原厂安卓私有驱动/固件/配置** —— 素材确实在（本地
`TMP/stock-rom-research/extracted/p15fs/` 与 `p15_filelist.txt`）：

| 类别 | 原厂 Android 里的私有组件 |
|---|---|
| GPU 用户态 | `/lib/egl/libGLES_mali.so`(1,087,560 B)、`libEGL.so`、`libGLESv1_CM/v2.so`、`egl.cfg` |
| 编解码 OMX HAL | `libOMX.hisi.video.decoder.so`、`.encoder.so`、`libOMX_Core.so`、`libHV.VIDEO.FFMPEG_VDEC.decode.so` |
| HiSilicon 中间件 | `libhi_msp.so`(870 KB)、`libhi_common.so`、`libhi_vp.so`、`libhi_gfx2d.so`、`sample_venc` 等 |
| 内核侧接口 | `/dev/mali*`、`/dev/mmz_userdev`、`/proc/msp/*`、`mmz=ddr,0,0,400M` |

但**不能直接搬到 Debian + 主线 6.3**：
1. 用户态库是 Android **bionic** + gralloc/hwcomposer/ashmem/binder 依赖，
   glibc 系统上跑不起来；OMX 也没有对应的 V4L2/VA-API 适配层。
2. 内核侧 GPU/VDEC/VENC 是**内建进 vendor 3.x/4.4 内核**的（原厂解包出的 `.ko`
   只有 USB/WiFi/NTFS 之类，没有 mali/vdec），与 6.3 的 DRM/V4L2/设备模型 ABI
   不兼容，无法直接加载。
3. 还依赖私有 `hi_mmz`（Media Memory Zone）—— 正是 §4.3 里用主线
   `reserved-memory` 替代掉的那个内存管理机制，主线没有 `hi_mmz` 驱动。

**结论**：原厂私有栈作为**参考实现 / 寄存器初始化序列 / 固件**有价值（与之前
显示驱动 RE 同理，可反编译提取），但作为"直接复用的驱动"不可行。真正要硬解
只能把 vendor 多媒体子系统整体 backport 到 6.3（工作量远大于本项目显示驱动
的 backport，应另立项）。

**建议分档**：
- GPU：走主线 `lima`（小改动、一轮 CI 可验证），但网关用途非必需，优先级 P2。
- 硬解：先装 `ffmpeg` 软解实测 1080p H.264 帧率，确认是否够用；不够再评估
  vendor backport。
- 保持现状对"双 USB 网络存储网关"完全够，本轮不改内核 config（避免与正在
  跑的 release 构建叠加）。

### 7.2 社区 4.4 内核 / SDK / 跨 SoC 同型号 GPU 复用（用户追问）★

用户追问：社区 4.4 内核里是否做了 GPU 与媒体编解码？SDK 里有无相关资料？
若能找到**其他 SoC 上的同型号 GPU**，是否有可能拿来用？逐一查证：

#### 7.2.1 社区 4.4 内核：**内核侧确实有**，但用户态没接上

社区 4.4 与原厂 Android 用的是**同一个 Hisilicon vendor SDK 内核**，只是把
rootfs 换成 Ubuntu。证据：

| 证据 | 内容 |
|---|---|
| 社区内核自带 cmdline | `mem=1G mmz=ddr,0,0,60M`（p2 env 各档为 `mmz=ddr,0,0,48M`）—— **MMZ 媒体内存区**，证明内核内建了多媒体子系统 |
| 社区 4.4 DTB (`flash_analysis/kernel.dts:423`) | `gpu@0xf9200000`，`compatible="arm,mali-450","arm,mali-utgard"`、`clock-names="clk_mali"`、`mali-supply` |
| 同 DTS `:444` 的 `interrupt-names` | 列出 `vdec_vdh` / `vdec_scd` / `vdec_vdh_safe` / `vdec_scd_safe` / `venc` / `vpss0` / `tde` / `jpeg` / `png` / `vdp` / `gpu` —— SoC 硬件里这些多媒体 IP 都实装并各占一条中断 |
| 内核镜像 `strings` | 能扫到 `vdec_scd` / `vdec_vdh` / `venc` / `arm,mali-450` / `gpu@0xf9200000` / `#clk_mali` / `mali-supply` —— 驱动/设备名编进了内核 |
| 原厂 `/lib/modules/*.ko` 清单 | 只有 WiFi/USB/NTFS 类（`rtl8188fu.ko`、`ehci-hcd.ko`、`tntfs_hisilicon.ko`…），**没有 mali/vdec 的 .ko** → 印证它们是**内建**而非模块 |

**但社区 Ubuntu 用户态是空的**：`box_backup/community_etc_opt.tar.gz`（社区
Ubuntu 的 `/etc`+`/opt`，1510 条）里只有 `etc/modules-load.d/modules.conf`、
`etc/X11/`、`etc/modprobe.d/*` 等通用配置，**没有任何** `mali`/`vdec`/`omx`/
`hi_` 的模块加载或 HAL；512 MiB 的 `www_ecoo_top.raw` 也扫不到
`libGLES_mali` / `libOMX` / `libhi_msp`。即内核驱动在、却无用户态调用者，
**社区系统实际上没用上 GPU 与硬解**。这与用户此前"社区 4.4 没有实现显示
画面"的观察一致：换了 Ubuntu rootfs，私有 HAL 没跟过来。

> 修正 §7.1 的一处措辞：`vdec_vdh`/`vdec_scd`/`venc` 在社区 DTB 里只是
> **中断线命名**，不是 V4L2 设备节点；vendor 驱动不走标准 DTB platform 绑定，
> 而是内核内自行注册，这也是它无法直接移植到主线的原因之一。

#### 7.2.2 SDK 资料：有，但都是 Android 用户态 HAL

本地留存的 SDK/原厂素材（`TMP/stock-rom-research/`、`stock-partition-backups/`、
`docs/027`、`docs/052`、`RESEARCH-NOTES.md`）里能找到完整私有栈：
`libGLES_mali.so`(1,087,560 B)、`libEGL.so`、`libGLESv1_CM/v2.so`、
`libOMX.hisi.video.decoder/encoder.so`、`libOMX_Core.so`、
`libHV.VIDEO.FFMPEG_VDEC.decode.so`、`libhi_msp.so`(870 KB)、
`libhi_common.so`、`libhi_vp.so`、`libhi_gfx2d.so`、`/bin/sample_venc`，
以及内核侧 `/dev/mali*` / `/dev/mmz_userdev` / `/proc/msp/*`。
`RESEARCH-NOTES.md:12` 已定性为"专有的 Android 用户态 HAL（gralloc /
hwcomposer / hidisplay / libhi_msp / Mali EGL）" —— **bionic + Android HAL**，
glibc 系统上跑不起来，也没有 V4L2/VA-API 适配层。作为寄存器序列/固件参考
有价值，作为可直接复用的驱动不可行（§7.1）。

#### 7.2.3 跨 SoC 同型号 GPU：**能，而且不用找 —— 主线 lima 已经做了**

这是本轮最有价值的发现。Mali-450 是 **Arm 的通用 GPU IP**，不是海思私有：

| 证据 | 内容 |
|---|---|
| 主线 `lima_drv.c:463` 的 `dt_match` | `{ .compatible = "arm,mali-400" }` / `{ .compatible = "arm,mali-450", .data = lima_gpu_mali450 }` —— **按 GPU IP 型号匹配，完全不绑定 SoC 厂商** |
| 主线内核里 `arm,mali-450` 出现的 SoC | **14 个 DTS**，横跨 5 家厂商：Amlogic `meson8/meson8b/meson-gxbb/meson-gxl/gx-mali450`、Rockchip `rk3328`、Allwinner `sun50i-h5`、MediaTek `mt7623n`、HiSilicon `hi3796mv200/hi3798mv200/hi3716dv100/hi6220`，以及本板 `hi3798mv100` |
| 跨 SoC 范例 `rk3328.dtsi:605` | `compatible = "rockchip,rk3328-mali", "arm,mali-450"` —— 厂商特有串 + 通用 fallback，lima 匹配后者即可驱动；节点只有 `reg`/`interrupts`/`clocks` |
| 本板 `hi3798mv100.dtsi:464` | 属性**比 rk3328 还全**：`reg`、8 个中断带 `interrupt-names`、`clocks`(bus/core)、`resets`、`mali-supply`、8 档 OPP(150–500 MHz)、`#cooling-cells`；唯一缺的是 `status="disabled"` |
| `flash_analysis/modules.tar.gz` | 是 **6.14.3 主线内核**的模块包，内含 `lima.ko`（不是社区 4.4 的）—— 佐证 lima 可独立编成模块 |

**结论**：不需要移植海思私有驱动，也不需要"另找"同型号 GPU 的驱动 ——
主线 `lima` 本身就是这个跨 SoC 通用驱动。落地只要 ① DTS `status="okay"`
② 启用 `CONFIG_DRM` + `CONFIG_DRM_LIMA`（Kconfig 依赖 `DRM`/`MMU`/
`COMMON_CLK`/`OF`，自动 select `DRM_SCHED`/`DRM_GEM_SHMEM_HELPER`/
`PM_DEVFREQ`/`DEVFREQ_GOV_SIMPLE_ONDEMAND`）③ `&crg` 提供
`HISTB_GPU_BUS_CLK`/`HISTB_GPU_GP_CLK`（cmdline 已有 `clk_ignore_unused`）
④ 用户态 Mesa `lima_dri.so` + libdrm。一轮 CI 可验证。

#### 7.2.4 但 VDEC 不能跨 SoC 复用

`vdec_vdh`/`vdec_scd` 是**海思自研私有 IP**，不是 Arm 那种跨厂商授权核。
主线 6.3 的 V4L2 M2M 硬解驱动 `drivers/media/platform/verisilicon/`(hantro)
的 compatible 全是 `rockchip,*-vpu` / i.MX 等，对应 VeriSilicon G1/G2 VPU，
与海思 VDH 寄存器/固件完全不同；`drivers/media/` 里 hisilicon 只有红外遥控
(`rc-hix5hd2.c`)，**零视频编解码驱动**；本板主线 DTS 里也只有 Mali 节点、
无 `vdec`/`venc`/`codec` 设备节点。所以硬解没有"其他 SoC 同型号"可借，
只能整体 backport vendor 多媒体栈（大工程）或走软解。

#### 7.2.5 小结

| 目标 | 跨 SoC 复用可行？ | 推荐路径 |
|---|---|---|
| **GPU (Mali-450)** | **是**，主线 lima 已通用化 | 启用 `CONFIG_DRM_LIMA` + DTS okay + Mesa，P2、小改动 |
| **VDEC/VENC (海思 VDH)** | **否**，私有 IP 无同类 | vendor backport（另立项）或软解；先实测 ffmpeg 1080p H.264 |
| 社区 4.4 内核驱动 | 内核侧有、用户态无 | 可作寄存器/初始化序列参考，不可直接搬 HAL |

---

## 8. 本轮已落地的代码改动

| 文件 | 改动 | 目的 |
|---|---|---|
| `scripts/apply-dts-placeholders.py` | vendor-backport 路径注入顶端 32 MiB `reserved-memory`（无 `no-map`），地址由 DDR 尺寸推导 | **修花屏根因**（§4.3） |
| `scripts/build-rootfs.sh` | PACKAGES 加 `iw rfkill dnsutils netcat-openbsd`；`/etc/network/interfaces` 写死接口名改 `wlan0` | 基础网络工具内置、修 WiFi 配置 |
| `rootfs/usr/local/bin/ec6108-wifi` | 动态探测接口、改用 `wpa_supplicant`+networkd、去掉 `ifup`、不杀进程 | 修 WiFi 连接脚本 |
| `patches/vendor-display/hi3798mv100_vendor_display.c` | `BOOT_MARK_LINES` 240 → **24** | 绿带缩小到约 1/10，减少晃眼，保留排障可见性；文字区反而多约 14 行 |
| `scripts/build-rootfs.sh` | `/etc/issue` 改用 agetty `\4`/`\6` 转义（单引号 heredoc + sed 占位符替换）；新增 `ec6108-issue-refresh.service`；`/etc/network/interfaces` 精简为只有 `lo`；helper 统一 `chmod 755` | 登录界面实时显示 IPv4/IPv6；修 systemd `degraded`（§11.2/§11.3） |
| `rootfs/usr/local/bin/ec6108-issue-refresh` | 新增：有界等待全局地址后 `try-restart` console getty，且跳过 tty1 已有登录会话 | 保证开机首次登录提示就带真实地址（§11.2） |
| `scripts/build-rootfs.sh` | 内置静态 `resolv.conf` 兜底 + `ec6108-dns-init.service`；PACKAGES 加 `systemd-timesyncd` + `fake-hwclock`；写 `timesyncd.conf.d`、`/etc/fake-hwclock.data`、`/usr/lib/clock-epoch`、enable symlinks | 根治 DNS（§11.5）、NTP 与软件 RTC（§11.6） |
| `rootfs/usr/local/bin/ec6108-dns-init` | 新增：开机从 DHCP DNS 重建 `resolv.conf`（网关优先 + 公共兜底） | 修 DNS（§11.5） |

（commit message 遵循仓库风格、无任何 AI Agent 追加信息 / trailer；
所有推送内容已检查不含本机绝对路径与用户名。）

---

## 9. 待办 / 跟踪清单（编号供后续引用）

| # | 优先级 | 事项 | 状态 |
|---|---|---|---|
| P0-1 | 高 | 刷入含 §4.3 显存保留的包，验证花屏消失、TTY 正常、apt 不再 segfault | **已验证 ✓**（§11.1） |
| P0-2 | 高 | 时间：无硬件 RTC，冷启动必回旧时间 | **已根治 ✓**（§11.6：`fake-hwclock` 文件式软件 RTC + `clock-epoch` + `systemd-timesyncd` NTP） |
| P1-1 | 中 | DNS：统一 `systemd-resolved` 或静态 resolv.conf，消除"stub 文件 + 无服务" | **已根治 ✓**（§11.5，静态兜底 + 开机从 DHCP 重建） |
| P1-2 | 中 | ~~TCP 出口受限~~（首轮误判） | **关闭**：§2.2 复测直连全通（`apt-get update` RC=0、下载 149 KB 成功），系 IPv6 优先 + DNS/时钟故障叠加的假象，无需代理 |
| P1-3 | 中 | 把 `vim`/`git` 装进 rootfs（`iw`/`nc` 等已内置并实测可用） | 部分完成；`vim`/`git` 待定（加 PACKAGES 需评估 480 MiB 余量，§11.1） |
| P1-4 | 中 | `regulatory.db` 早期加载失败：评估是否内置进 `CONFIG_EXTRA_FIRMWARE` | 已定位，非致命（rootfs 内文件可用，§11.4） |
| P1-5 | 中 | 登录界面显示 IPv4/IPv6（§11.2）：固化 `build-rootfs.sh` 并出包 | 已落地，待 release 产物验证 |
| P1-6 | 中 | WiFi 实际关联 + DHCP 验证（扫描已通，§11.4） | 待用户提供 SSID/密码 |
| P1-7 | 中 | `ifup@wlan0.service` 导致 systemd `degraded`（§11.3） | 已修（interfaces 精简），在线验证回到 `running` |
| P2-1 | 低 | `nmcli`：按 §5.3 方案评估是否引入 NetworkManager | 待用户决定 |
| P2-2 | 低 | 文件系统：补 `UDF_FS`/`HFSPLUS_FS` + 用户态 fs 工具 + NFS/CIFS 服务端 | 内核基础已够 |
| P2-3 | 低 | GPU：启用 `CONFIG_DRM_LIMA`（DTS 节点 `status="disabled"`，需改 okay + Mesa）；硬解走私有栈另立项 | **已调研（§7.1/§7.2）**：Mali-450 是 Arm 通用 IP，主线 `lima` 已跨 14 个 SoC 通用，改动小可落地；VDEC 是海思私有 IP 无跨 SoC 复用可能；社区 4.4 内核有驱动但 Ubuntu 用户态没接上 |
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

# 装包（TCP 出口直连可用，无需代理；见 §2.2 更正）
apt-get update && apt-get install -y --no-install-recommends <pkg>
curl -4 -O <url>          # DNS 优先返回 AAAA 而盒子无全局 IPv6 时，强制 IPv4

# 显示 / 显存
dmesg | grep -iE "hi3798-vd|fb0|reserved mem"
cat /sys/class/graphics/fb0/name
ls /dev/dri /dev/video* /dev/media* 2>/dev/null

# WiFi
lsusb; iw dev; iw dev IFACE scan | grep -E 'SSID|signal|RSN'; rfkill list
iw reg get; dmesg | grep -iE "rtl8xxxu|firmware|cfg80211"
ec6108-wifi '<SSID>' '<password>'; iw dev wlan0 link; ip -br addr show wlan0

# 登录界面 / IP 显示（无需拍屏：/dev/vcs1 直接读屏）
cat /etc/issue
cat /dev/vcs1 | tr -d '\000' | fold -w 100 | head -18
systemctl status ec6108-issue-refresh.service
systemctl restart getty@tty1.service      # 让 issue 改动立即显示

# 文件系统
grep -E "CONFIG_(NTFS3|EXFAT|VFAT|BTRFS|XFS|F2FS|UDF|HFSPLUS)_FS" /path/to/config
```

> 凭据、开发机地址与本机路径不写入本报告；仅保留复现所需的形式化占位符。

---

## 11. 第二轮真机探测（刷入「全部修复版」后，DHCP 地址尾号 .103）

### 11.1 上一版修复全部生效 ✓

| 项 | 实测证据 |
|---|---|
| 显存保留（§4.3） | `OF: reserved mem: 0x3e000000..0x3fffffff (32768 KiB) map non-reusable framebuffer-reserved@3e000000`；`map`（非 `no-map`）= 仍是 System RAM，`memremap(WB)` 不失效；`fb0 1920x1079@0x3f6ce000` 落在区间内。本轮未再出现彩色噪点/条带 |
| locale（§6.2） | `/etc/default/locale` = `LANG=C.UTF-8`；`locale -a` = `C / C.utf8 / POSIX`；sshd `AcceptEnv LANG` 已注释 |
| 基础网络工具 | `iw rfkill dig nslookup nc nano iwconfig iwlist wpa_supplicant wpa_passphrase` 全部在；`nano` 本来就有 |
| 480 MiB rootfs | 根 `6.7G / 361M 已用`，`dpkg --audit` 空（健康），不再解包 segfault |
| 内核/cmdline | `6.3.0-rc5+`，`rootwait rootwait_timeout=30`、`fbcon=map:0`、`net.ifnames=0` 均在 |

`vim`、`git` 仍缺（§9 P1-3）：本轮没有把它们加进 PACKAGES —— 上两轮
`mke2fs -d` 因镜像尺寸连续失败，加 `git` 会显著抬升 payload；需要时在线装
或单独评估尺寸后再固化。

### 11.2 新需求：登录界面直接显示本机 IPv4 / IPv6

用户痛点：每次要靠路由器查 DHCP 地址才能 SSH。`/etc/issue` 原来写死
`ssh root@<dhcp-ip>` 占位符，屏幕上看到的仍是占位文字。

**方案（原生、零新依赖）**：util-linux 2.38.1 的 agetty 支持 `/etc/issue`
转义 `\4` / `\6`（及 `\4{iface}` / `\6{iface}`），每次 getty 启动时展开成
本机 IPv4 / IPv6；实测在 tty2 起一个临时 getty 后 `/dev/vcs2` 读屏：

```
IPv4_all   : <BOX_LAN_IP>
IPv4_eth0  : <BOX_LAN_IP>
IPv6_all   : <LINK_LOCAL_IPV6>
IPv6_eth0  : <LINK_LOCAL_IPV6>
```

`\4` 不带参数即主 IPv4，`\6` 给出 IPv6，`\4{iface}` 语法同样有效。

**`/dev/vcsN` 是直接读屏幕文字的关键技巧**（VT 屏幕缓冲区，纯文本），
本轮所有登录界面验证都靠 `cat /dev/vcs1 | tr -d '\000' | fold -w 100`，
不需要拍照或 OCR。

最终 `/etc/issue`（单引号 heredoc 保留反斜杠 + sed 填占位符）：

```
EC6108V9C / Hi3798MV100 - Debian bookworm armhf

  Network addresses:
    IPv4   \4
    IPv6   \6

SSH:    ssh root@\4        (password: <ROOT_PASSWD>)
Telnet: telnet \4          (plaintext, change the password first)
Serial: ttyAMA0 115200
WiFi:   ec6108-wifi '<SSID>' '<password>'   (then: iw dev wlan0 link)
```

把 WiFi 连接命令也印进登录界面，避免再忘。

**开机时序兜底**：agetty 只在启动时展开一次，可能早于 DHCP 拿到地址。
新增 `ec6108-issue-refresh.service`（oneshot，`After=systemd-networkd.service
getty@tty1.service`）+ `ec6108-issue-refresh` 脚本：有界等待全局 IPv4
（12×0.5s），若 tty1 已有登录会话则跳过，否则 `try-restart` console getty
重画提示。重启 tty1 后 `/dev/vcs1` 读屏确认 `IPv4 <BOX_LAN_IP>`、
`IPv6 <LINK_LOCAL_IPV6>`、`ssh root@<BOX_LAN_IP>` 均正确展开。

### 11.3 systemd `degraded` 根因与修复

`systemctl is-system-running` 原为 `degraded`，唯一 failed 单元是
`ifup@wlan0.service`：

```
ExecStart=/bin/sh -ec ifup --allow=hotplug wlan0; ...  -> status=1
/etc/network/if-pre-up.d/wpasupplicant: cannot create /dev/stderr
```

根因：上一版 `/etc/network/interfaces` 里保留 `allow-hotplug wlan0` +
`wpa-conf`（指向尚不存在的 `wpa_supplicant.conf`），udev 因此触发
`ifup@wlan0.service`，与已 mask 的 ifupdown / networkd 分工冲突。
**修复**：interfaces 只保留 `lo`，所有接口交由 networkd；删掉该 stanza 后
`reset-failed` 并重启，`is-system-running` 回到 `running`、`--failed` 为空。

### 11.4 WiFi 实测（本轮扫描）

| 项 | 结果 |
|---|---|
| 芯片/驱动 | `0bda:f179 RTL8188FTV`，`rtl8xxxu` 内置固件 `Firmware revision 4.0` |
| 接口 | `wlan0`，`rfkill` 无软/硬封锁，`iw dev` 正常 |
| 扫描 | `ip link set wlan0 up` 后 `iw dev wlan0 scan` 成功，扫到 10+ 个 2.4G AP（含中文 SSID），链路可用 |
| regulatory | `iw reg get` 正常（world domain `00`）；`regulatory.db` 符号链接指向 `regulatory.db-debian`，文件存在；dmesg 那条 `Direct firmware load ... failed` 是 rootfs 挂载前的早期请求，非致命 |
| 未做 | 未真正关联 AP —— 需要 SSID/密码；`ec6108-wifi` 脚本已就绪（写 wpa conf + `wpa_supplicant` 关联，DHCP 交给 networkd） |

连接命令：

```
ec6108-wifi '<SSID>' '<password>'
iw dev wlan0 link            # 看关联状态
ip -br addr show wlan0       # 看 DHCP 拿到的地址
```

### 11.5 DNS：**上一版没根治，本轮实测确认并修好** ★

用户追问 DNS，实测结论：**确实没解决**（上一轮只是在线临时覆盖
`/etc/resolv.conf`，没写进 rootfs，重刷全回退）：

| 检查 | 实测 |
|---|---|
| `/etc/resolv.conf` | 普通文件（非 symlink），内容是 debootstrap 从**构建主机**继承的 stub 模板：`nameserver 127.0.0.53` + `options edns0 trust-ad` + 一个 CI runner 的内网 `search` 域 |
| `systemd-resolved` | `not-installed`，无 unit 文件，`resolvectl` 不存在 → `127.0.0.53` 无人监听 |
| `/run/systemd/resolve/` | 不存在 |
| `getent hosts deb.debian.org` | **FAIL** |
| `networkctl status eth0` | `DNS: <GW>` —— networkd **已经**从 DHCP 拿到了正确网关 DNS，只是精简 rootfs 里没有任何机制把它写进 `resolv.conf` |

**修复（零新包、零新守护进程）**：
1. rootfs 内置一份**静态兜底** `/etc/resolv.conf`（公共 DNS），保证刷机后立即可解析；
2. 新增 `ec6108-dns-init.service`（oneshot，`After=systemd-networkd.service`）
   + `ec6108-dns-init`：开机用 `networkctl status eth0` 的 `DNS:` 行提取 DHCP
   DNS，重建 `resolv.conf`（网关 DNS 优先，公共 DNS 兜底）。不引入
   `systemd-resolved`/`resolvconf`，避免再动依赖与镜像尺寸。

在线实测（RC=0）：

```
# generated at boot by ec6108-dns-init (DHCP DNS + public fallback)
nameserver <GW>
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
options timeout:2 attempts:2
getent hosts deb.debian.org -> 解析成功
```

### 11.6 时间：软件 RTC + NTP（用户追问）★

用户追问"NTP 服务似乎也没解决？RTC 也没解决？"，并明确指出：即便没有硬件 RTC，
也应该用 **基于文件的软件 RTC**（Debian 对 RTC-less 设备的标准做法），不能放弃。
据此把首轮"RTC 不做"的结论推翻，实测与修正如下：

| 检查 | 实测 | 结论 |
|---|---|---|
| `/dev/rtc*` / `/proc/driver/rtc` | 均不存在 | 无硬件 RTC 设备 |
| 内核 `CONFIG_RTC*` | config fragment 里一项都没有；DTB 无 rtc 节点 | 主线内核没启用 RTC class |
| `timedatectl`（首轮） | `RTC time: n/a`、`NTP service: n/a` | 冷启动必然丢时间 |
| `systemd-timesyncd` | 首轮 `not-installed` | NTP 客户端缺失 |
| `/usr/lib/clock-epoch` | 首轮不存在 | systemd 时间下限缺失 |
| `fake-hwclock` | 首轮 `not-installed`；apt 候选 `0.12+nmu1` 可用 | 软件 RTC 缺失 |
| **UDP/123 出口** | `ntp.aliyun.com` 0.05s、`cn.pool.ntp.org` 0.28s、`time.windows.com` 0.10s、`pool.ntp.org` 0.26s 全部收到 48B NTP 响应（仅 `time.google.com` 超时） | **NTP 完全可达** |

**关于硬件 RTC**：机顶盒无 RTC 电池，主线 6.3 未启用 `CONFIG_RTC_CLASS`、DTB 无
rtc 节点，硬件 RTC 确实不存在；但这**不等于时钟问题无解** —— 应按 Debian 对
Raspberry Pi 等无 RTC 设备的标准方案，用**文件式软件 RTC** 兜住冷启动，再由
NTP 精校。若将来要真正的硬件 RTC，需另立项（内核启用 RTC class + Hisilicon
RTC 驱动 + DTS 节点 + 硬件电池），非本项目必需。

**根治（本轮已落地，Debian 标准三件套）**：
1. **`fake-hwclock`**（PACKAGES 加入）：`fake-hwclock.service` 开机
   `ExecStart=/sbin/fake-hwclock load`、关机 `ExecStop=/sbin/fake-hwclock save`，
   数据在 `/etc/fake-hwclock.data`；postinst 自动 enable 到
   `sysinit.target.wants`。实测 save/load 往返成功，且 `load` **默认拒绝回拨**
   （`saved clock information is in the past ... use force`），不会覆盖
   timesyncd 已同步的更晚时间，两者不冲突。
2. **`/usr/lib/clock-epoch`**：systemd ≥ 246 在 PID1 启动时以该文件 mtime 作为
   系统时钟下限；构建时 `touch` 它，保证刷机后首次开机时间不倒退。
3. **`systemd-timesyncd`** + `timesyncd.conf.d/10-ec6108.conf`（实测可达的 NTP 池）。
4. 构建时把 `/etc/fake-hwclock.data` 预置为构建时刻，首次开机（尚未联系 NTP）
   就是合理日期，离线时 apt 也不会被 `Release ... not valid yet` 卡住。

在线验证（装包走 **TCP 直连**，见 §2.2 更正）：

```
fake-hwclock save  -> /etc/fake-hwclock.data = <BUILD_DATE>
date -s '+1 day'   -> fake-hwclock load 恢复(并提示 saved clock is in the past)
timedatectl status -> System clock synchronized: yes / NTP service: active
journalctl: Contacted time server <NTP_IP>:123 (ntp.aliyun.com)
```

### 11.7 仍待处理

- `vim`/`git`（PACKAGES 已有 `vim-tiny`）、NTFS 自动挂载 fstab、NM/nmcli 分工（§5.3）等按 §9 清单推进。
- 本轮所有 rootfs 改动需经 CI 出包后真机刷入验证（制品以 CI 为准）。
- TCP 出口结论已在 §2.2 更正（直连可用、无需代理），不再列为待办。
