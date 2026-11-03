# 原厂设备软硬件深度分析（EC6108V9C / Hi3798MV100）

- 分析日期：2026-11-03
- 对象：局域网内一台原厂未改机的 EC6108V9C（中国移动定制 IPTV 机顶盒）
- 手段：ADB（tcp 5555，root shell，SELinux Disabled）读取系统信息；整机分区已全量备份
- 相关文档：`001-boot-and-flash-analysis.md`、`004-hiboot-vs-uboot-analysis.md`

## 1. 设备身份

| 项目 | 值 |
|---|---|
| 型号 | EC6108V9（`ro.build.office=HBYD_EC6108V9`） |
| 运营商定制 | 中国移动（`ro.cmcc.device=stbroute`、`ro.hw.sys.hotline=10086`、白名单含 `com.jscmcc.*` 江苏移动） |
| ONT 配对型号 | `EC6108V9_ONT / HS8125T`（`/system/etc/EC6108V9_ONT_HS8125T.prop`） |
| 厂商码 | ManufacturerCode 0008 / Huawei |
| 硬件版本 | `V100R003C82LHED01B015`，模块标识 `HMW830212b`、`MOBILY-HYBIRD` |
| 固件 | Android 4.4.2 / `5.2.0.B243SPC003` / `V.890.26`，构建于 2018-04-24 |
| 平台代号 | `ro.board.platform=bigfish`（海思 STB 平台代号） |

## 2. 硬件

| 部件 | 结论 | 依据 |
|---|---|---|
| SoC | HiSilicon Hi3798MV100 | `ro.product.`、内核 `Linux 3.10.0_s40`、DTB/驱动 |
| CPU | 4× Cortex-A7（`CPU part 0xc07`），VFPv4 + NEON，600/1000/1200/1500 MHz，governor=interactive | `/proc/cpuinfo`、cpufreq |
| 内存 | 1 GB（MemTotal 1015924 kB） | `/proc/meminfo` |
| 存储 | eMMC 8 GB（CID 前缀 `008G30`，manfid 0x11 = Toshiba），逻辑容量 7634944 KB | `/sys/class/mmc_host/mmc0/mmc0:0001` |
| 有线网 | HiSilicon 内置 MAC（`hieth`/`higmac`），当前 down；env 里 `phy_intf=mii,rgmii use_mdio=0,1 phy_addr=2,1` | env、`/sys/class/net/eth0` |
| 无线 | **Realtek RTL8188F**（USB 接口，设备名 `802.11n`，挂在 1-2 端口），2.4G 802.11n | `dmesg`、`/sys/bus/usb/devices` |
| 蓝牙 | CSR8510（`ro.hw.sys.btusb=csr8510`），MAC 已存在（`persist.service.bdroid.bdaddr`） | props |
| 音频 | HISI-AIAO（海思音频子系统），HDMI 输出使能 | `/proc/asound/cards` |
| 显示 | HDMI + CVBS 双输出，当前 1280x720p，CEC 关闭 | `/sys/class/graphics/fb0/modes`、props |
| 输入 | 内部 IR/面板键盘（`Hi keyboard`/`Hi mouse`/`qwerty`） | `/sys/class/input/*/name` |
| USB | 2× EHCI + 2× OHCI（HiUSB），其中一路内接 WiFi 模块 | `/sys/bus/usb/devices` |
| 接口 | HDMI、AV(CVBS)、RJ45、USB×2、电源、红外接收 | 硬件形态 + 软件节点 |

## 3. 存储布局（原厂）

分区不是磁盘分区表，而是 bootloader 通过 `bootargs` 的 `blkdevparts` 让内核识别：

```
1M(fastboot) 4M(bootargs) 16M(recovery) 1M(deviceinfo) 4M(baseparam) 4M(pqparam)
4M(logo) 16M(fastplay) 8M(misc) 24M(factory) 12M(kernel) 8M(iptv_data)
340M(backup) 340M(cache) 520M(system) -(userdata)          eMMC 7.28 GiB
```

偏移（MiB）：fastboot 0 / bootargs 1 / recovery 5 / deviceinfo 21 / baseparam 22 /
pqparam 26 / logo 30 / fastplay 34 / misc 50 / factory 58 / kernel 82 / iptv_data 94 /
backup 102 / cache 442 / system 782 / userdata 1302。

实测印证：
- 82 MiB 处为 `ANDROID!` 魔术 → 确为 Android boot.img（kernel 分区）
- `/system` 392 MB 已用 / 520 MB，`/data` 3.6 GB 已用 / 5.8 GB，`/cache` 空

## 4. 引导链

```
BootROM(eMMC) → p1 fastboot/hiboot → 读 p2 环境(CRC32 校验) → 加载 boot.img(82MiB)
→ Linux 3.10.0_s40 → Android init
```

- hiboot 版本：`Fastboot 3.3.0-00786-g908d79f-dirty (root@HW-TV-S3) (Aug 06 2016)`
- 与社区包镜像同源（同为 U-Boot 3.3.0 分支的 HiSilicon fastboot），但为 2016 年原厂构建
- 已验证能力：`mmc write.ext4sp`（sparse 直写）、`bootargs.bin` 从 U 盘按 CRC 加载、`fatload`、`go`、`ddr training`、`getinfo`

## 5. 启动环境变量（p2，CRC 有效）

```
verify=n
baudrate=115200  ipaddr=192.168.1.10  serverip=192.168.1.1  netmask=255.255.255.0
bootfile="uImage"
phy_intf=mii,rgmii  use_mdio=0,1  phy_addr=2,1  gmac_debug=0
bootcmd=mmc read 0 0x1FFBFC0 0x4B000 0x5000; bootm 0x1FFBFC0
bootargs=console=ttyAMA0,115200 blkdevparts=mmcblk0:1M(fastboot),4M(bootargs),...
signature_check=sign:recovery,recovery,0x200000 sign:kernel,kernel,0x700000
```

要点：
- `verify=n`：**镜像签名校验关闭**；`signature_check` 只是声明，未生效
- 环境与 U-Boot 完全同构：4 字节 CRC32 + `key=value\0`（本机 CRC 校验通过）
- **疑点**：`bootcmd` 中的 `0x4B000`（LBA，≈150 MiB）指向 `backup` 分区，实测该处无内核镜像；
  而真实 boot.img 在 82 MiB（`kernel` 分区）。说明原厂正常启动并不走这条 `bootcmd`
  （hiboot 内部有 Android boot.img 加载路径），该行更像历史遗留/备用。
  这一点对改造刷机有直接影响，见第 8 节。

## 6. 系统层

| 项 | 值 |
|---|---|
| Android | 4.4.2（API 19），`KOT49H`，`eng` 构建、`test-keys` |
| 内核 | `Linux 3.10.0_s40`，2018-06-30 构建，`chenxi@huawei-199` |
| SELinux | **Disabled**（`getenforce`） |
| ADB | `ro.adb.secure=1` 但 adbd 直接给 root shell（eng 构建 + SELinux 关闭） |
| 属性 | 411 条，含运营商/播放器/HDMI/音频/网络定制项 |
| 预装应用 | 72 个，核心为华为 STB 套件 + 运营商客户端 |

预装应用分类：
- 华为框架：`com.huawei.iptv.stb.manage`、`com.huawei.hmt.*`（测试/配置/蓝牙遥控）、`com.huawei.upgradeonline`（在线升级）、`com.huawei.stb.xmpp`
- 启动器：`com.xinjing.launcher`、`com.chinamobile.activate`
- 播放器/内容：`com.hisilicon.android.videoplayer`、`org.xbmc.kodi`、`com.gitv.tv.gvp`、`com.cibn.tv`、`com.ktcp.video`
- 投屏：`com.hpplay.happyplay.aw`（乐播）
- 语音：`com.iflytek.xiri2.system`
- 其它直播/点播 APK 多个

## 7. 运营商定制痕迹

- `/system/etc/DevinfoConfig.xml`：EPG / CMS / CDN / 广告平台地址、TVID、STBMAC 等参数模板
- `/system/etc/DevinfoAppConfig.xml`：**应用白名单**，含 `com.chinamobile.*`、`com.gitv.*`、`tv.icntv.*`、`com.jscmcc.*`（江苏移动）、`com.bestv.*`
- `/system/etc/EC6108V9_ONT_HS8125T.prop`：与华为光猫 HS8125T 配对使用的型号覆盖
- DHCP 定制：`ro.hw.sys.net.dhcp.opt60/opt61`（IPTV 终端厂商类/Vendor ID）
- 质量监控：根目录 `sqmpro`/`sqmsign.ini`/`sqmfactor.ini`（SQM 探针）

## 8. 对 Debian 改造项目的直接影响

1. **布局必须切换**：原厂与社区 Debian 布局完全不同。我们的刷机包写 kernel@14 MiB、rootfs@610 MiB，
   同时写 p2 的新 `blkdevparts`，刷完分区语义整体切换 → 原 recovery/factory/backup/cache/system 被覆盖。
   已做全量备份（见第 9 节），可回滚。
2. **hiboot 能力已满足**：原厂 hiboot 就支持 `bootargs.bin` + `write.ext4sp`，理论上原厂固件就能执行我们的 U 盘脚本。
3. **bootcmd 疑点**：原厂 env 的 `bootcmd` 指向 150 MiB（该处无镜像），而真实 boot.img 在 82 MiB。
   原厂 hiboot 内含 `Android_Main`/`bootimg`/`boot-recovery` 等 Android 专用代码，
   说明正常启动很可能走内置 Android 路径，而非 env 的 `bootcmd`。
   该问题尚未在本机实测，专项分析与分阶段验证方案见 `007-boot-path-analysis.md`。
4. **签名校验关闭**：`verify=n`，无需签名即可引导自制镜像（利好改造）。
5. **eMMC 布局注意**：写入点 14 MiB 落在原 `recovery`（5–21 MiB）内，20 MiB 内核区会溢出到 deviceinfo/baseparam 起点，
   与社区布局一致，属预期行为。

## 9. 已完成的整机备份

- 方式：设备上 `dd` 到 U 盘（FAT32，29.3 GB），USB 写入速度约 30 MB/s
- 内容：16 个分区 + eMMC boot0/boot1，共 17 个文件、7.3 GB
- userdata 6.0 GB 按 FAT32 单文件 4 GB 限制拆为 `_a/_b/_c` 三段（2048 + 2048 + 2058 MiB）
- 附带 `README.txt`（完整偏移表与恢复命令）与 `BACKUP.log`（分区表 + 每文件 md5）
- 关键小分区同时在恢复镜像中单独存档：`p01_fastboot`、`p02_bootargs`（含完整 env）、`p04_deviceinfo`

## 10. 结论

- 这是一台 **2018 年固件的中国移动定制 EC6108V9（Hi3798MV100，1 GB/8 GB）**，硬件与社区 Debian 包面向的机型一致。
- 原厂 hiboot 已是 U-Boot 3.3.0 系定制版，支持 sparse 直写与 U 盘环境覆盖，具备改造条件；签名校验关闭。
- 主要风险不在硬件，而在**分区布局切换**与**hiboot 启动路径**；前者已有完整备份兜底，后者需首次刷机时用串口确认。
- 原厂固件可直接作为回滚源（p01–p16 全量镜像 + 偏移表），建议把备份放到独立存储并保留至少两份。

## 附录：采集命令

```
adb connect 192.168.3.183:5555
adb shell getprop
adb shell cat /proc/{cpuinfo,meminfo,cmdline,partitions}
adb shell cat /proc/device-tree/... (无设备树，Android 4.4 + ATAG)
adb shell cat /sys/class/mmc_host/mmc0/mmc0:0001/{name,cid,csd}
adb shell dmesg            # 被 RTL8188F 日志刷屏，仅 190 行
adb shell pm list packages
adb shell df
adb pull /dev/block/mmcblk0pN   # 二进制安全（adb shell 直传会被 CR 转换破坏）
```
