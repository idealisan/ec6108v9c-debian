# 057 — 无串口环境下的 SSH-only 验证清单

> 2026-11-19。前提：拿不到 ttyAMA0 串口，**唯一可用的成功判据是盒子拿到 DHCP 地址并能 SSH 登录**。
> 配合 `docs/053` 的 L0/L1/L2 与 `docs/056` 的 P0 使用。本文只讲操作与采集，不改变构建产物。

## 1. 刷机阶段（不需要串口）

使用 release 中 **recovery-flasher 包**（`mv100-mdmo1g-mainline-recovery-flash-*.zip`）：

1. U 盘 FAT32/MBR，解压到根目录，保留 U 盘根目录的社区 `fastboot.bin`。
2. 断电 → 插 U 盘 → 短接恢复键上电。
3. HDMI 上应出现滚动的 `<数字> <TEXT>` 终端日志；**必须看到 `6 DONE NO REBOOT`** 才算写完。
   - 这一步不依赖 7.4 内核，用的是 stock recovery 3.10 内核，是已知可验证的通道。
   - 若 HDMI 无输出，不要假设成功：换一个显示器/线，或改用 legacy community 包再试。
4. 断电、拔 U 盘、正常上电（**不要用 SSH reboot**，6.3 上 warm reboot 曾失败）。

## 2. 启动阶段（只看网络）

1. 等待 3–5 分钟（首启要 `resize2fs` 扩容 p8，比平时慢）。
2. 在路由器 DHCP 列表里找新设备（此前常见 `192.168.3.102`；若 DHCP 租约被占，看新租约的 MAC）。
3. 判定：

| 现象 | 结论 | 下一步 |
|---|---|---|
| 出现 IP，SSH 可登录 | **L2 通过**，内核与 rootfs 至少已启动 | 进入 §3 采集 |
| 出现 IP，但 SSH 连接被拒 | rootfs 起来了，sshd 未就绪 | 等 1 分钟再试；仍不行试 telnet 23 |
| 始终无 IP | 内核/根挂载失败 | 无串口时无法进一步定位；先重刷，再换 legacy 包；不要盲改内核参数 |

## 3. SSH 登录后一次性采集（原样贴回，便于比对）

```sh
{
  echo '=== 内核与命令行 ==='
  uname -a
  cat /proc/cmdline
  echo '=== 运行时间 ==='
  uptime
  echo '=== 根挂载 ==='
  findmnt / && grep mmcblk0p8 /proc/mounts
  echo '=== 网络 ==='
  ip -br addr && ip route
  echo '=== CMA ==='
  grep -E 'CmaTotal|CmaFree' /proc/meminfo
  echo '=== DRM/GPU ==='
  ls -l /dev/dri/ 2>/dev/null
  lsmod | grep -E 'histb|lima|sii9134|drm'
  echo '=== 关键 probe 日志 ==='
  dmesg | grep -iE 'histb-vdp|sii9134|lima|mmc0|hisi-femac|rt8xxxu|rtl8xxxu|thermal|sp805|root device|panic|oom|out of memory'
  echo '=== 显示/温度 ==='
  cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null
  fbset -i 2>/dev/null | head -20
  echo '=== 用户态图形（若装了） ==='
  DISPLAY=:0 glxinfo -B 2>/dev/null | grep -E 'renderer|Vendor|OpenGL renderer'
} 2>&1 | tee /tmp/verify-$(date -u +%Y%m%dT%H%M%SZ).txt
```

把生成的 `/tmp/verify-*.txt` 内容贴回即可；如能下载，放到项目内 `TMP/`（未入库）。

## 4. 判据速查

| 判据 | 期望值 | 不达标意味着 |
|---|---|---|
| `uname -r` | `7.4.0-rc2` | 刷的不是 7.4 包 |
| `/proc/cmdline` | 含 `root=/dev/mmcblk0p8`、`rootwait`、`cma` 相关或 `media_cma` 生效 | 根设备错会静默卡住 |
| `findmnt /` | 设备为 `/dev/mmcblk0p8` | 挂到别的分区会丢修改 |
| `CmaTotal` | ≥ 163840 kB（160MiB 媒体池） | 显存池不足，GPU 模式易硬锁 |
| `/dev/dri/card0` | 存在（VDP KMS） | 显示驱动未注册 |
| `/dev/dri/renderD128` | 存在（lima） | GPU 渲染节点缺失 |
| `dmesg` 中 `sii9134` | bridge bound | 无 bridge 则 KMS card 不注册 |
| 连续在线 30 分钟 | 不掉线 | 掉线说明 GPU 渲染或 CMA 问题 |

## 5. 操作护栏

- **不要**用 `reboot`/`shutdown -r`，用断电重启。
- **不要**再试用户态 mmap fb0 / `gpu_fb` / `gpu_show`（`docs/054` 已证伪并导致死机）。
- **默认软件渲染**是稳定态；`gpu-mode` 切换后若盒子掉线，断电重刷默认配置。
- 如果 SSH 一直不通，且 HDMI 刷机日志也没有 `6 DONE NO REBOOT`，优先怀疑 U 盘/短接/供电，而不是内核。
- 每次只改一个变量并记录，结果追加到 `docs/056` 提到的验证日志，不改写历史结论。
