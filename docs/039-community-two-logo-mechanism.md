# 039 — 社区刷机包「两张图片」的实现机制与显示阶段（U 盘原件实证）

> 2026-11-08。用户观察：社区刷机包里有两张经过修改的图片，一张「较早看到」，
> 另一张「刷机成功后正常启动 Ubuntu 时画面一直停留」；并明确说明阶段归属只是猜测。
> 本轮用 U 盘上**社区版原件**（`mv100-mdmo1g-usb-flash.zip`，295 MB）实证还原机制。
>
> 方法（`docs/033` REA 规范）：format-aware 解析 + 严格图片验证（SOF/EOI、PNG chunk 链、
> ext4/sparse inode 路径），**不靠文件名/魔数猜**；区分 `[观察]` / `[推断]` / `[未知]`。
> 相关：`docs/031`（hiboot 四问）、`docs/036`（刷机执行者）、`docs/037`（改 p1 NO-GO）、
> `docs/016`（社区包解剖）、`docs/023`（recovery 显示逆向）。

---

## 0. 结论先行（直接回答「两张图分别在什么阶段」）

> **两张图都不是「刷机过程中实时显示」的，也都不是 Linux 内核画的。**
> 它们都是 **hiboot 在正常开机路径画的 p5 logo 分区内容**，区别在于
> **同一块 p5 被写了两次、由两次不同的开机各画一次**：

| | 图 A（较早看到） | 图 B（刷好后 Ubuntu 一直停留） |
|---|---|---|
| 内容 | 社区 U 盘 `mv100/logo.img` 内的 JPEG，924×529，54,221 B，SHA256 `73e7f6e5…` | p7 `/etc/bootargs/logo.img` 内的 JPEG，924×529，238,426 B，SHA256 `321eb2bd…` |
| 谁写进 p5 | **U 盘刷机链**的 `flashlogo`：`mmc write 0 0x1000000 0x5000 0x120` | **p7 OpenWrt 的 `/etc/recovery.sh`**：`dd of=/dev/mmcblk0p5 if=/etc/bootargs/logo.img bs=1024 count=4096` |
| 何时写 | 短接上电跑 `bootcmd` 时（刷机链中段） | 刷完 `reset` → 启动进 **p7 busybox(OpenWrt)** → `/etc/rc.local` 调 `recovery.sh` 时 |
| 何时被显示 | 刷机链 `reset` **之后**那次开机，hiboot 画 p5 | `recovery.sh` 最后 `reboot` **之后**那次开机，hiboot 画 p5 |
| 之后为何一直停留 | — | 内核起来后**没有 fbcon/VT、也没有用户态往 fb 画东西**，画面停在 hiboot 留下的那张图 |

→ 用户「一张刷机时、一张 Linux 启动时」的猜测**方向对、阶段错**：
两张都是**开机（bootloader）阶段**的图，第二张之所以看起来像「Linux 启动过程」，
是因为它在 p7 恢复系统跑完后才被写入、并在随后开机才显示，时间上紧邻 Ubuntu 启动。

---

## 1. 输入与完整性（U 盘原件）

- 对象：U 盘顶层 `mv100-mdmo1g-usb-flash.zip`（295,142,013 B），11 个条目；
  `mv100/` 内 9 个文件与本地副本 `TMP/community-restore/mv100/` **逐字节一致**（8 个 SHA-256 全 SAME）。
- 该 zip 里**没有独立的第二张图片文件** → 两张图都嵌在容器内部。
- 严格图片验证结果（`TMP/community-images/`，共 25 张）：
  - 全尺寸 924×529 JPEG **仅 2 张**（就是上面的 A / B）；
  - 其余 23 张是 p7 里 16×16 / 30×24 的 PNG 小图标（OpenWrt web UI 资源），与显示画面无关；
  - `hi_kernel.bin` 里 2 处 JPEG 魔数、`fastboot.bin` 里 12 处 `BM` 魔数、
    `logo.img` 里 `BMP@0x6712` —— 全部是**假阳性**：
    后者落在图 A 的 JPEG 数据区间 `0x2000..0xF3CD` 内，解析出的「尺寸」是乱码
    （`0x6712` 处 `u32` 读成 3657201655），内核里那两处 SOF 也得到 28844×53361 之类荒谬值。
    → 按 `docs/033 §2` 第 3 条，靠魔数/布局下的「第二张图」结论一律剔除。

---

## 2. 两张图的容器结构（同构、不同内容）

两者都是 HiSilicon **LOGO_TABLE** 容器，字段逐项一致：

| 字段 | 图 A（`mv100/logo.img`） | 图 B（p7 `/etc/bootargs/logo.img`） |
|---|---|---|
| 头部 | `###\0` + table len `0x7c` @`0x04` | 同 |
| 表名 | `LOGO_TABLE` @`0x08` | 同 |
| `LOGO_KEY_FLAG` | 1 @`0x50` | 1 |
| `LOGO_KEY_LEN` @`0x78` | **54,221** | **238,426** |
| JPEG 起点 | `0x2000` | `0x2000`（容器基址 `0x664178` + `0x2000` = `0x666178`） |
| 尺寸 | 924×529（`sips` 验证可解码） | 924×529（`sips` 验证可解码） |
| 容器总长 | 65,536 B（p5 分区写入 0x120×512=144 KiB，实占 64 KiB） | 253,952 B（inode 85 size，`recovery.sh` 写 4096×1024=4 MiB 上限） |

→ **[观察]** 同一格式、同一分辨率，只有图片内容与 `LOGO_KEY_LEN` 不同。
这正是「社区包里两张经过修改的图片」：作者换了两次同一张广告图的内容。

---

## 3. 两个阶段的完整链条（实证）

### 3.1 阶段 1：U 盘刷机链写图 A

U 盘顶层 `bootargs.bin`（CRC OK）里：

```
loadfilel=fatload usb 0 0x1000000 mv100/logo.img
flashpartitionl=mmc write 0x0 0x1000000 0x5000 0x120      ; p5 logo 分区
flashlogo=run loadfilel flashpartitionl
bootcmd=run flashfastboot; run flashbootargs; run flashbase; run flashpq; \
        run flashlogo; run flashkernel; run flashrootfs; run flashbackup; reset
```

→ **[观察]** `flashlogo` 只是把 `mv100/logo.img`（图 A）写进 p5，**不含显示动作**
（`docs/031 §2.3` 已证 `logo` 不是 U-Boot 命令、命令表无显示命令）。
刷机链执行期间屏幕不刷新 HDMI（`docs/031 §3`）。

### 3.2 阶段 2：p7 恢复系统把 p5 换成图 B

`reset` 后进 p7（社区 `root=/dev/mmcblk0p7` 的 busybox/OpenWrt），
`/etc/rc.local` 调用 `/etc/recovery.sh`：

```sh
#!/bin/sh
platform=$(uname -m)
if [ "$platform" = "aarch64" ]; then arch=64
elif [ "$platform" = "armv7l" ]; then arch=32; fi

flash_partition9() {
    mkdir -p /backup
    mount -t ext4 /dev/mmcblk0p8 /backup
    gunzip -c /backup/backup-$arch.gz | dd of=/dev/mmcblk0p9 conv=fsync
}
echo "正在恢复系统刷机中，不要操作！不要断电！"
flash_partition9                                   # 解压 Ubuntu 根到 p9
resize2fs /dev/mmcblk0p9
dd of=/dev/mmcblk0p2 if=/etc/bootargs/bootargs9-${arch}.bin bs=1024 count=1024 conv=fsync   # 切 root=p9
dd of=/dev/mmcblk0p5 if=/etc/bootargs/logo.img bs=1024 count=4096                          # ★ 写图 B 覆盖 p5
sleep 2; sync; umount /backup; reboot
```

`/etc/bootargs/` 目录内容（inode 82）：`bootargs9-32.bin`(83)、`bootargs9-64.bin`(84)、`logo.img`(85)。
`bootargs9-32.bin` 的 `root=/dev/mmcblk0p9`、`bootcmd=mmc read ...; bootm ...`（正常开机）。

→ **[观察]** 图 B 是在 **p7 Linux 已起来之后**，由用户态 `recovery.sh` 用 `dd` 写进 p5 的；
写完后 `reboot`，下一次开机 hiboot 画的就是图 B。
→ **[推断]** 这就是「刷好之后正常启动 Ubuntu 时画面一直停留」的由来：
Ubuntu 内核起来后没有 fbcon/VT 绑定、没有用户态 blit（`docs/023 §5.1`、
`docs/035 §6`），所以屏幕保持在 hiboot 画下的 p5 内容，不会切换到 TTY。

### 3.3 时间线

```
短接上电 ──> p1 hiboot 跑 U 盘 bootcmd
              ├─ flashfastboot 写 p1 / flashbootargs 写 p2(root=p7) / flashbase 写 p3 / flashpq 写 p4
              ├─ flashlogo   写 p5 = 图 A   ★第 1 次写 p5
              ├─ flashkernel 写 p6 / flashrootfs 写 p7 / flashbackup 写 p8
              └─ reset
                 ──> 开机 #1：hiboot 画 p5 = 图 A  →「较早看到的图」  ★第 1 次显示
                      └─ 内核进 p7 busybox → /etc/rc.local → recovery.sh
                           ├─ 解压 p8 到 p9、resize2fs
                           ├─ dd bootargs9-*.bin 到 p2（root=p9 ubuntu）
                           └─ dd /etc/bootargs/logo.img 到 p5 = 图 B   ★第 2 次写 p5
                              └─ reboot
                                 ──> 开机 #2：hiboot 画 p5 = 图 B  →「Ubuntu 一直停留的图」 ★第 2 次显示
                                      └─ Ubuntu 内核起来，不接管显示 → 画面停在图 B
```

---

## 4. 对本项目此前结论的影响（重要）

1. **再次印证 `docs/031 §3`**：社区包刷机链**同样没有在刷机过程中实时显示**。
   两张图都是「写 p5 → 之后开机由 hiboot 画」。用户「刷机时显示一张图」的直觉应修正为
   「刷机链把图写进 p5，reset 后的开机才画」。
2. **社区包确实实现了「两次不同的开机画面」**，但不是靠改 p1、也不是靠 env 状态机，
   而是靠 **p7 中间系统 `recovery.sh` 二次覆写 p5**。
   → 这给 `docs/036 §4` 的路径取舍补了一条**已验证可行**的先例：
   分阶段显示可以用「中间系统二次写分区 + reboot」实现，无需改 hiboot 二进制。
   代价是需要一个能启动的 Linux 中间系统（社区有 p7 busybox，我们目前没有）。
3. **图 B 的显示者仍是 hiboot，不是 Linux 内核**：
   `dd` 只写分区，显示发生在下一次开机。
   → 与 `docs/035 §6`「原厂只有内核 hifb + 用户态 blit、没有 fbcon」一致，
   也解释了用户长期观察到的「社区 Ubuntu 只显示广告画面、不出 TTY」。
4. **对改 p1 的 go/no-go 无直接影响**：`docs/037` 的 NO-GO 依据是
   「无显示载荷 + 写 p1 不可逆」，本轮未改变这两条；`docs/038`（BootROM U 盘加载假设）
   仍是唯一可能推翻它的支点，调研进行中。

---

## 5. 提取产物（供人工核对，gitignored 不入库）

- `TMP/community-images/KEY/A_logo-img_p5.jpg` — 图 A，54,221 B，`73e7f6e5…`
- `TMP/community-images/KEY/B_recoverybox32_p7.jpg` — 图 B，238,426 B，`321eb2bd…`
- `TMP/community-images/` 下另有 23 张 16×16/30×24 PNG 小图标及
  `recoverybox32.raw.ext4`（sparse 解出的 64 MiB 原始 ext4）。
- 用户核对结论（2026-11-08）：A = 较早看到的一张；B = 刷机成功后正常启动 Ubuntu 时一直停留的图。
  与本文 §3 的链条一致。

---

## 6. 可复现与合规

- 解析脚本为一次性 Python（LOGO_TABLE / JPEG SOF+EOI / PNG chunk / Android sparse /
  ext4 超级块+组描述符+extent+目录项），产物全在项目内 `TMP/community-images/`。
- U 盘 **只读**，未写入、未改动任何 U 盘文件；未刷机、未改真机、未构建镜像、未删文件。
- 未联网；未访问项目目录之外的本地目录（U 盘为任务指定对象，只读）。
- 描述本地资源用仓库内相对路径，**不含本机绝对路径 / 用户名 / 卷名**；
  用户消息中出现的本机路径未写入任何文件。
- 结论按 `docs/033 §2` 标注 `[观察]` / `[推断]` / `[未知]`；
  「假阳性」单列，不把魔数命中当图片证据。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
