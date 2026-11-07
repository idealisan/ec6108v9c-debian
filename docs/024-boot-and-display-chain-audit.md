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
