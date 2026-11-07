# 024 — 启动引导 + 显示链路审查（刷机前）

> 目标：在刷机**之前**把"能不能启动、能不能看到日志"这两条最基础的链路
> 逐环节走一遍，把问题定位到具体文件/行，而不是刷完再猜。
> 方法：纯静态（脚本、DTS、内核源码、CI 日志、SDK 源码），不碰设备。
> 日期：2026-11-07，对应 CI run `42367068057`（"能刷的版本"）。

---

## 0. 结论速览

| 环节 | 状态 | 说明 |
|---|---|---|
| U 盘刷机脚本 env / CRC | ✅ | 3 个写入目标、长度、顺序都自洽 |
| 内核 uImage 打包 / 加载地址 | ✅ | `0x1FFFFC0` + 64B 头 = `LOADADDR 0x2000000` 精确对齐 |
| p6/p8/p2 的 LBA 与分区布局 | ✅ | 98 MiB 起点、482 MiB 终点，**不碰社区 p9(610 MiB)** |
| DTB cmdline 覆盖机制 | ⚠️ | 可能被 hiboot 的 ATAG cmdline 覆盖，但结果基本等价（见 §2.4） |
| `mem=1G` / `/memory@0` | ✅ | 两处都是 0x40000000，互为兜底 |
| `FB_SIMPLE` / `FRAMEBUFFER_CONSOLE` | ✅ | CI 日志实测 `=y`，DRM_SIMPLEDRM 未启用 |
| `console=tty0` | ✅ | 已进 cmdline（这是之前 HDMI 无输出的确定缺陷，已修） |
| 显示驱动读 VO 图层寄存器 | ⚠️ | 偏移有 SDK 依据，但**hiboot 用哪个图层未验证**（见 §3.3） |
| **pstore / ramoops 日志兜底** | ❌ | **编译进内核但没激活**（见 §3.5）—— 这是唯一确定要补的缺口 |
| 显存与内核 RAM 冲突 | ⚠️ | 见 §3.6 |

---

## 1. 刷机流程（U 盘 → eMMC → reset）

`scripts/make-community-flash-package.sh` 生成顶层 `bootargs.bin`（CRC32 env）：

```
bootcmd=run flashkernel; run flashrootfs; run flashbootargs; reset

flashkernel   = fatload ... mv100/hi_kernel.bin  → mmc write 0 0x1000000 0x7000  $K_HEX
flashrootfs   = getinfo ddrfree; fatload ... mv100/debian-root.ext4
                → mmc write.ext4sp 0 0x1000000 0x31000 $R_HEX
flashbootargs = getinfo ddrfree; mw.b ...; fatload ... mv100/bootargs.bin; crc32 ...
                → mmc write 0 0x1000000 0x800 0x80
```

核对结果：

- `K_SECTORS = ceil(hi_kernel.bin / 512)`，脚本检查 `> 40960`（20 MiB）就报错；
  p6 分区正好 `20M(kernel)` ✅
- `R_SECTORS = IMG_SIZE_MB * 2048 = 384 * 2048 = 786432 = 0xC0000`
  → 写入 LBA `0x31000 .. 0xF1000` = **98 MiB .. 482 MiB** ✅
- 8 分区布局 `1+1+4+4+4+20+64 = 98M`，rootfs 从 98 MiB 开始 ✅
- 社区布局 p9 从 **610 MiB** 开始 → 482 < 610，**刷失败也不破坏社区系统** ✅（这是 384 MiB 相对 1 GiB 的关键收益）
- `loadfiler` 已补 `getinfo ddrfree`（与社区包一致，`docs/018`/`TMP/刷机失败排查说明.txt` 的待办）✅
- `bootcmd` 末尾 `reset` 存在 → 刷完会回到正常启动流程（hiboot 才初始化 HDMI）✅

> 上一轮失败的原因（1 GiB sparse / 410 MB fatload / `0x200000` 扇区写入卡死）
> 已由"裁剪 rootfs 到 ~248 MiB + 镜像 384 MiB + sparse ~219 MiB"解决。

---

## 2. 正常启动流程（hiboot → 内核）

### 2.1 p2 运行时 env

`runtime.env`：`bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0`

- `0x7000` = p6 起点（14 MiB），读 `0xA000` 扇区 = 20 MiB 到 `0x1FFFFC0` ✅
- uImage 头 64 字节在 `0x1FFFFC0`，payload 从 `0x2000000` 开始
- `build-kernel.sh` 的 `LOADADDR=0x2000000`，`mkimage -a/-e` 都用它
- `0x2000000 - 0x1FFFFC0 = 0x40 = 64` → **精确对齐**，无需重定位 ✅

### 2.2 DTB 追加与 cmdline

`CONFIG_ARM_APPENDED_DTB=y`、`CONFIG_ARM_ATAG_DTB_COMPAT=y`（defconfig）：
`cat zImage dtb > zImage-dtb` → mkimage 包装 ✅

`0001` 补丁注入 `/chosen/bootargs = "__CMDLINE__"` 与 `/memory@0`：
- `KERNEL_CMDLINE` = `model=mv100 clk_ignore_unused console=tty0 console=ttyAMA0,115200 root=mmcblk0p8 ... blkdevparts=...(8分区)... mem=1G` ✅
- `/memory@0 reg = <0x0 0x40000000>` = 1 GiB ✅ 与 `mem=1G` 一致
- `console=tty0` 已就位（之前只有 ttyAMA0 → fbcon 不会接管）✅

### 2.3 根文件系统

`root=mmcblk0p8` 与 8 分区 `-(debian)` 一致；ext4 镜像由 `mke2fs -d` 生成后
转 Android sparse；`resize-rootfs.service` 首启扩容 ✅

### 2.4 ⚠️ ATAG cmdline 覆盖风险（需真机确认，但结果等价）

`arch/arm/boot/compressed/atags_to_fdt.c`：

```c
if (atag->hdr.tag == ATAG_CMDLINE) {
    if (do_extend_cmdline)                 /* CONFIG_...CMDLINE_EXTEND 未启用 → 0 */
        merge_fdt_bootargs(fdt, ...);      /* 拼接 */
    else
        setprop_string(fdt, "/chosen", "bootargs", atag->u.cmdline.cmdline); /* 覆盖 */
}
```

即：若 hiboot 的 `bootm` 往 r2 传 ATAG list（传统 U-Boot 行为），
**ATAG_CMDLINE 会整体覆盖 DTB 的 `/chosen/bootargs`**——这与
"`/chosen/bootargs` 覆盖 bootloader" 的直觉相反，前提是 bootloader 没传 ATAG。

但影响可控，因为**我们刷进 p2 的 bootargs 与 DTB 的内容几乎相同**：

| 项 | DTB bootargs | p2 bootargs (ATAG) |
|---|---|---|
| `console=tty0` | 有 | 有 |
| `clk_ignore_unused` | 有 | 有 |
| `root=mmcblk0p8` + 8 分区 blkdevparts | 有 | 有 |
| `mem=1G` | 有 | **无**（但 `/memory@0` 节点给 1 GiB） |

→ 即使被覆盖，启动参数仍正确。唯一差异是 `mem=1G` 换成 DT 的 `/memory@0`，
效果等价。**记录为风险，不必改动。**

---

## 3. 显示流程（hiboot → 6.x 内核 → HDMI）

### 3.1 已确认正确的部分

- `CONFIG_FB_SIMPLE=y`、`CONFIG_FRAMEBUFFER_CONSOLE=y`、`CONFIG_VT=y`
  —— CI run `42361378514` 日志中 `verify key options` 实测为 `=y` ✅
  （`FB_SIMPLE` 依赖 `!DRM_SIMPLEDRM`；defconfig 只有 `DRM=m`，未启用
  `DRM_SIMPLEDRM`，故 `olddefconfig` 没有把它关掉）
- `clk_ignore_unused` 保住 hiboot 配好的 VO/HDMI 时钟 ✅
- 驱动为 `subsys_initcall`（level 4），early enough for fbcon；
  `simplefb` 的 `module_platform_driver` 是 device_initcall（level 6），
  platform bus 会在 driver 注册时匹配已存在 device ✅
- `get_kernel_nofault()` 读 MMIO 不会 oops ✅
- `simplefb_platform_data` + `IORESOURCE_MEM` 动态注册路径经内核源码核对 ✅

### 3.2 驱动当前实现（依据 SDK 反编译结果，见 docs/023）

读 `VO_REG_BASE 0xf8cc0000 + G0_ADDR 0x494 / G0_STRIDE 0x49c / G0_IRESO 0x4a0`
→ 拿显存地址、stride、分辨率 → `memremap` 校验有像素 → 注册 simplefb。
兜底：ioremap HDMI TX bank (`0xf8ce0000`) 扫 DDR 地址值。

### 3.3 ⚠️ 需真机验证：hiboot 用的是哪个图层

- `S_VDP_REGS_TYPE` 里 `G0_ADDR` 偏移经 SDK 交叉验证 ✅
- 但 hiboot 画 logo 可能用 **GP0 / WBC 图层**而非 G0；
  SDK 的 `CONFIG_HIFB_GP_OFFSET = 0x800`，GP0 的 ADDR 会在另一偏移
- 若 G0_ADDR 读不到有效地址，驱动会走 HDMI TX 扫描兜底；
  若仍找不到，则 warn 后退出（不破坏启动），此时**只剩 pstore 能兜日志**
- 另：`fbprobe` 扫的是 `0xf9000000-0xfa000000`（VDP v4 区），
  与驱动读的 `0xf8cc0000`（hifb 图层寄存器区）不是同一窗口

### 3.4 ❌ 确定缺口：pstore / ramoops 没有激活

`configs/kernel/ec6108v9c.config` 已把
`CONFIG_PSTORE=y / PSTORE_RAM=y / PSTORE_CONSOLE=y` 编进内核，
但**没有任何地方告诉 ramoops 用哪块内存**：

- `EXTRA_CMDLINE` 展开为空（无 `ramoops.mem_address=`）
- DTS 里没有 `compatible = "ramoops"` 的 reserved-memory 节点

→ `fs/pstore/ram.c` 的 `mem_address` 为 0，ramoops 不会注册，
**panic 日志一条都留不下**。

这是"两个链路都走不通时唯一能看到日志"的最后兜底，必须补。
修复方式（二选一，均不依赖真机）：
1. DTS 里加 `reserved-memory` ramoops 节点（需选一块不与显存/内核冲突的地址），或
2. `EXTRA_CMDLINE` 填 `ramoops.mem_address=<addr> ramoops.mem_size=0x100000`
   并用 `memmap=` / DT 保留该区域

由于社区实测显存落在 965 MiB 附近，ramoops 区域应避开 DDR 顶端，
建议放在 `0x30000000`（768 MiB）附近并用 `memmap=1M$0x30000000` 保留。
**此项在刷机前应补齐。**

### 3.5 ⚠️ 显存与内核 RAM 冲突

社区内核实测 `smem_start = 0x3c55c000`（**965 MiB**），而我们的
`mem=1G` + `/memory@0` 把整块 1 GiB 都交给内核。若 hiboot 的 logo
显存也落在 DDR 顶端，这块内存可能已被内核分配；simplefb 再往里写会
破坏内核数据。

postmarketOS 的做法是在 DTS 里用 `reserved-memory` + `no-map` 把
bootloader 显存永久排除。我们的显存地址是运行时从寄存器读的，
静态 DTS 做不到；可选项：
- 把 `mem=` 缩到显存之下（如 `mem=768M`），代价是损失内存
- 驱动早期 `memblock_reserve()`（`subsys_initcall` 太晚，需更早的 hook）
- 若真机出现"HDMI 有字但很快死机"，优先怀疑这里

**记录为风险，真机观察后再定。**

---

## 4. 待办清单（按优先级）

1. ❌ **补 pstore/ramoops 激活**（§3.4）—— 唯一确定要改的项
2. ⚠️ 真机确认 hiboot logo 图层（G0 vs GP0/WBC）：驱动打印
   `VO layer0: addr=... stride=... ireso=...`，若 addr=0 则需改读 GP0
3. ⚠️ 真机确认显存与内核 RAM 是否冲突（§3.5）
4. ⚠️ 真机确认 ATAG cmdline 是否覆盖（§2.4）—— 看启动后 `/proc/cmdline`
5. 若 2/3 失败 → 转 `docs/022` §6 第二阶段：自己初始化 HDMI/VO，
   照搬 SDK `HDMI_Display()` 序列（原厂 recovery 同款路径）

---

## 5. 参考

- `docs/021` 驱动移植路线 / `docs/022` 设计与两阶段方案
- `docs/023` 原厂 recovery 显示机制逆向与 VO 寄存器偏移
- `docs/018` §10 刷机速查 / `TMP/刷机失败排查说明.txt`
- `scripts/make-community-flash-package.sh` / `scripts/build-kernel.sh`
- `configs/partition-layout.env` / `configs/kernel/ec6108v9c.config`
- CI run `42361378514`（verify key options 日志）

---

## 6. 补记（真机刷机后）：为什么「看到 Debian Linux 画面」几乎不能证明什么

刷机包顶层 `bootargs.bin` 里真正执行的命令链是（`scripts/make-community-flash-package.sh`
的 `flash.env`）：

```text
bootcmd=run flashkernel; run flashrootfs; run flashbootargs; run flashlogo; reset
```

**关键事实：U-Boot hush 用 `;` 分隔时，前一条命令失败不会中断后面的命令。**
所以：

- `flashlogo` 是**最后一步**，看到「Debian Linux」只说明整条链**跑到了末尾**、
  `reset` 也执行了、hiboot 重启后从 p5 读出了新 logo；
- 它**不证明** `flashkernel` / `flashrootfs` / `flashbootargs` 的 `fatload` 或
  `mmc write` 成功写入了有效数据——任何一步报错都会被 `;` 吞掉；
- 对照组：社区包（已验证能刷成功）把 `flashlogo` 排在**中间**，最大的 rootfs
  `flashbackup` 排在**最后**。也就是说即便在已知可用的流程里，logo 也不是
  完成标志。我们把标记放在最后一步，等于选了信息量最弱的位置。

另需澄清分区：本包**从不写 p1（hiboot/fastboot）**，U 盘救援通道始终完好。
被改写并被 hiboot 画到屏幕上的是 **p5（logo 分区）**。真正决定能否进 Linux 的
只有 **p6（kernel uImage）** 和 **p8（rootfs）**；p2 的运行时 `bootcmd` 与社区包
完全一致（`mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0`），即使 p2
没写对，引导路径也不会因此改变。

**因此「画面停在 logo、无 IP、无任何内核输出」对应三种互斥可能，此前完全无法区分：**

| 现象 | 含义 |
| --- | --- |
| A 内核根本没起来 | p6 写入失败 / uImage 或 DTB 或 `mem=` 问题 / 早期崩溃 |
| B 内核起来了但显示没接管 | simplefb / fbcon 未绑定，或显存未被 `no-map` 保留 |
| C 内核起来了但网络/DHCP 没通 | SSH 与路由器列表都看不到，但屏幕本应有 TTY |

### 6.1 破除盲点：内核启动标记

`patches/kernel/hi3798mv100-hdmi-console.c` 在运行时从 VO 的 `G0_ADDR` 读出
hiboot 留下的显存地址后，**立刻把顶部 240 行刷成纯绿**，再去注册
`simple-framebuffer`。hiboot 已经在扫描这块显存（它画的 logo 用户看得见），
所以写入像素一定会显示出来，且不依赖 fbcon、`console=tty0`、网络、rootfs、串口：

- 绿色**留在屏幕上** → 内核确实启动并跑到 `subsys_initcall`，显存地址正确，
  问题收敛为 `fbcon`/`simplefb` 绑定（→ B）；
- 绿色被**内核日志覆盖** → 显示链路已通，可直接读日志定位网络（→ C）；
- **仍是 Debian Linux logo** → 内核没跑到该 initcall（→ A），下一步查 p6 写入
  与 uImage/DTB，而不是继续调显示。

只刷 240 行是刻意的：足以一眼辨认，又限制住万一地址探测错误时的破坏范围。
该标记是诊断手段，HDMI 确认可用后应移除。

### 6.2 已实施：串联刷机链 + 分阶段进度图

`scripts/make-community-flash-package.sh` 的 `bootcmd` 已从 `;` 改成 `&&`
串联，每个写入步骤内部也用 `&&` 保证 `fatload` 失败时绝不执行 `mmc write`；
每步成功后把一个独立的阶段 logo 写进 p5，`; reset` 无条件执行让 hiboot
重读 p5。hush 支持 `&&`（`fastboot.bin` 内含 `HUSH_VERSION`）。重启后画面：

| 画面文字 | 含义 |
| --- | --- |
| `0-4 START` | 脚本启动，但写 p6 kernel 失败 |
| `1-4 KERNEL OK` | p6 完成，但写 p8 rootfs 失败 |
| `2-4 ROOTFS OK` | p8 完成，但写 p2 env 失败 |
| `3-4 ENV OK` | p2 完成，但写最终 logo 失败 |
| `Debian Linux` | 四步全部完成（`4-4 DONE`） |
| 旧广告画面 | 什么都没执行（U 盘文件缺失或 bootcmd 被拒） |

`;` 串联 + 单末尾 logo 是这轮最大的设计缺陷：失败会被吞掉，最后仍显示
成功画面。现在「刷到哪一步」和「内核有没有起来」（§6.1 绿带）是两个独立
的可见信号，刷一次就能把 A / B / C 分开。

网络 / DHCP 侧的独立审计见 `docs/026-network-dhcp-audit.md`。

### 6.3 B 分支根因：离线能排除什么、不能排除什么

刷 `build-20261107T153551Z` 后如果落在 B（绿带出现、但 fbcon 无文字），
我们离线核对 6.3-rc5 内核源码后**证伪了三个直觉假设**：

| 假设 | 证伪依据 |
| --- | --- |
| "FB / fbcon / VT 没编译" | fragment 里 `CONFIG_FB` / `FB_SIMPLE` / `FRAMEBUFFER_CONSOLE` / `VT` / `VT_CONSOLE` 全部 `=y` |
| "simplefb 只认 DT 节点，运行时注册的设备不 probe" | `simplefb.c` 第 428 行 `dev_get_platdata()` 分支仍在，`simplefb_parse_pd()` 正常处理我们传的 pdata |
| "传的 `a8r8g8b8` 格式串不合法" | `include/linux/platform_data/simplefb.h` 的 `SIMPLEFB_FORMATS` 含 `a8r8g8b8` |

**剩下两个真实疑点（离线无法确证，需真机判据）：**

1. `fbcon` 绑定层。ARM 的 `arch/arm/include/asm/fb.h` 把
   `fb_is_primary_device()` 硬编码为返回 0；而 config 开了
   `CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y`，于是 `do_fb_registered()`
   里的 `fbcon_select_primary()` 永远不把我们的 simplefb 标为 primary。
   默认 `con2fb_map_boot[]` 是全 0、`info_idx=-1`、`deferred_takeover` 未开，
   理论上仍会走 `do_fbcon_takeover(1)` 接管 fb0——但这一层有任何偏差就会
   表现为"有 fb0 却无文字"。
2. **显存映射属性冲突（更可疑）**。`simplefb_probe()` 用 `request_mem_region`
   + `ioremap_wc()`，而 hiboot 留下的显存是 DDR 中的一段普通物理内存，
   我们**没有用 `reserved-memory` / `no-map` 把它从内核内存里排除**
   （`FB_BASE` 为空时 `apply-dts-placeholders.py` 只注入 ramoops）。
   同一物理页同时存在内核的 cacheable 线性映射和 fbdev 的 WC 映射，
   在 ARM 上可能导致写入不刷新到扫描输出。绿带用的是 `memremap(WB)`，
   与线性映射一致，所以它能显示而 fbcon 的文字未必——这正好解释 B。

### 6.4 本轮落地：B 分支候选修复（零代码风险，需判据确认）

`configs/partition-layout.env` 的 `KERNEL_CMDLINE_NO_MEM` 增加 `fbcon=map:0`：

- `fbcon.c` 第 492 行有 `__setup("fbcon=", fb_console_setup)`，`map:` 分支
  把 `con2fb_map_boot[]` 全部钉到 fb0 并调用 `fbcon_map_override()` 设
  `map_override=1`，使 `fbcon_select_primary()` 的 `!map_override` 条件为假，
  **整段跳过** ARM 上恒失效的 primary 检测（疑点 1）。
- 因为 `partition-layout.env` 是 DTB `/chosen/bootargs` 与 p2 运行时 env 的
  **单一来源**，两处自动同步，不会漂移。
- 纯 cmdline：不改 kernel config（`olddefconfig` 可能悄悄还原）、不改驱动、
  不重新编译显示栈。零风险，落在 A 或 C 也无害。

**必须诚实标注：这是候选修复，不是确证修复。** 它排除的是疑点 1；
如果疑点 2（显存 no-map）才是根因，这一版不会让文字出现。

**若本版仍无文字的下一步（有明确路径，不用再猜）：**

1. 用 pstore/ramoops 读出驱动打印的 `VO layer0: addr=0x...`，
   拿到 hiboot 显存的真实物理地址。
2. 把该地址作为 CI 的 `fb_base` 输入（workflow 已有该 input）重新发版：
   `apply-dts-placeholders.py` 会注入带 `no-map` 的 `fb_mem` 保留区和静态
   `simple-framebuffer` 节点，从根上消除映射属性冲突。
3. 再不行才启动 `mainline-porting` 分支的 plan B（见 `MAINLINE-PORTING.md`）。
