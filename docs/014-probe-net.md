# 探针的可观测信道：为什么屏幕没用，改用网络

- 日期：2026-11-04
- 背景：现场用 `bootcmd=reset` 探针时，屏幕全程不亮，"重启了"和"卡住了/开机太慢"无法区分。
- 结论：**原厂 hiboot 没有任何屏幕输出能力**，但**有完整网络栈**，探针改为发 ARP/ICMP 信标，用 PC 抓包判定。

## 1. 屏幕为什么不行（证据来自原厂 p1 反汇编/字符串）

解析 `cmd_tbl_t` 表（条目步长 0x1C，共 47 条命令）：

```
go reset bootm ddr fatload fatls fatinfo getinfo help ? hibernate
clear_bootf loadb loady uploadx md mm nm mw cp cmp crc32 base loop
mtest unzip mii mmcinfo mmc nand nboot bootp tftp rarpboot ping
saveenv printenv setenv usb usbboot version setproflag bootimg
otp_getcustomerkey otp_setstbprivdata otp_getstbprivdata otpreadall otpwrite
```

- 没有 `echo`、`logo`、`hdmi`、`bmp`、`fb` 之类的显示命令（`logo`/`hdmi` 只是函数名字符串）；
- 二进制里 `vidconsole`/`framebuffer`/`glyph` 命中数均为 0，控制台只有 `console=ttyAMA0,115200`；
- 唯一的显示路径是 `Logo_Main` → `PDM_ReadLogoData` → `HI_LOGO_DecImg`，
  只从 logo 分区解码开机图（`boot logo show!!!`），不能画任意内容，也不能写文字；
- 该路径在升级模式下是否执行都不由我们控制。

**所以"让屏幕显示点什么"在原厂 hiboot 上不可行**，除非另写内核（那就不是零写入探针了）。

## 2. 网络信道可用（同一张命令表）

```
ping     0x93DE4  do_ping         usage "send ICMP ECHO_REQUEST to network host"
tftp     0x93DAC  do_tftp
bootp    0x93D90  do_bootp        ("BOOTP broadcast %d")
rarpboot 0x93DC8  do_rarpboot      ("RARP broadcast %d")
mii               do_mii
```

驱动侧字符串：`Eth up port phy at 0x%02x is connect`、`up/down PHY not link.`、
`%s PHY not link.`、`*** ERROR: \`ethaddr' not set` —— 板载 PHY 驱动在 hiboot 里。

即：**hiboot 能自己起网口发 ARP/ICMP**，这就是不依赖屏幕的"串口替代品"。

## 3. probe-net 探针

`scripts/make-extra-packages.sh` 新增产物 `mv100-mdmo1g-probe-net-*.zip`，env 内容：

```
ethaddr=02:00:ec:61:08:01
ipaddr=192.168.3.240
netmask=255.255.255.0
gatewayip=192.168.3.1
serverip=192.168.3.1
bootcmd=ping 192.168.3.189; ping 192.168.3.254; reset
```

- `192.168.3.189` = 抓包 PC（本机 en16），命中会得到 ARP 应答 + ICMP reply；
- `192.168.3.254` = 不存在的主机，只发 ARP 广播（重试多次，很好抓）；
- `reset` → 循环，因此流量会周期性重复，**周期性**本身就是"在重启"的证据；
- 全程只有网卡收发，**没有任何 mmc write**。

抓包：

```bash
sudo tcpdump -n -e -i en16 'arp or icmp'
```

## 4. 判定

| 抓到 | 结论 |
|---|---|
| 出现 `192.168.3.240` 或 `02:00:ec:61:08:01`，且每隔几秒重复一次 | 原厂 hiboot 读了 U 盘 env 并执行了 bootcmd → 链路通，可进入下一阶段 |
| 毫无流量，盒子照常进 Android | env 未被消费（触发方式不对 / 文件没被找到）；无写入，可重试 |
| 毫无流量，盒子黑屏不动 | 停在 SoC USB 下载模式（BootROM，不跑 hiboot），或 hiboot 卡住；断电重试 |

## 5. 兜底

1. 先用 probe-net；若 PHY 一直不 link（完全没有流量），退回 `bootcmd=reset` 的普通探针看是否重启循环；
2. 最可靠的仍是**串口**（`ttyAMA0 115200`）：一个 CH340 就能直接看到 `bootargs crc failed`、
   `MMC read` 等打印，无需猜测。本项目所有"靠现象反推"的手段都只是等串口线的替代品。
