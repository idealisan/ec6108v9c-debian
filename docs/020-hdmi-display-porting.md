# 020 — HDMI 显示移植专项（最高优先级）

> 目标：让 6.x 内核在 HDMI 上输出文字控制台，从而在没有串口硬件的盒子上
> 看到内核启动日志与 panic 信息。**在这之前一切故障诊断都是盲的。**

---

## 1. 为什么这件事排第一

这台 EC6108V9C **没有串口硬件**（已确认），ttyAMA0 拿不到任何输出。
内核早期 panic 时网络/SSH 也起不来。因此 HDMI 是唯一可能的输出通道：

| 阶段 | 可用输出 |
|---|---|
| hiboot 刷机流程 | 无（刷机不需要显示） |
| 内核启动早期 | 串口（无硬件）、HDMI（待点亮）、pstore（待启用） |
| 系统完全起来 | SSH |

只要 HDMI 有一点输出，就能把"内核为什么起不来"从猜变成看。

---

## 2. 原理：两条显示路线

**社区 4.4 内核**：整套海思私有栈 `hifb / VO / VDP / HDMI + MMZ / MPP`，
内核主动初始化显示控制器，所以刷好之后一定亮屏。

**主线 6.x 内核**：没有这套驱动。但显示输出并不要求内核拥有整套栈 ——
Linux 主线有标准做法 **simple-framebuffer**：bootloader 已经把显示控制器
与时钟配好、并在持续扫描一块 DDR 内存，内核只需把这块内存的物理地址/
宽高/stride/像素格式写进 DTS，`simplefb + fbcon` 就能在**同一块显存**上画字。
这是 ARM 板子上 U-Boot / UEFI GOP 的常规交接方式。

**实证**：之前一次纯 SSH 部署（直接写 p6/p2/p8 后 reboot，不走 U 盘刷机流程），
用户明确观察到"重启后立即显示社区启动画面"，且我们的 6.x 内核起来后该画面
仍在 —— 说明 hiboot 在正常启动流程下确实配置了 HDMI/VO，且启动后 VO 仍在
持续扫描、时钟未被关掉（`clk_ignore_unused` 保障）。simplefb 的前提成立。

### 关于"刷我们的包时背光都不亮"

这与上面并不矛盾，是**另一个现象**：U 盘刷机时短接触点进入的是 hiboot
**刷机流程**，社区包刷完会 `reset` 回到正常启动流程才初始化 HDMI；而我们的包
卡在写 rootfs、从未执行到 `reset`，于是整晚停在刷机流程 —— 没画面、背光不亮，
与"20 分钟无变化"完全吻合。**它不能用来证明 hiboot 没配显示。**

推论：要让屏幕亮，除了 HDMI 参数正确，还必须让**刷机流程本身能走完并 reset**。
所以 §6 的"缩小 rootfs 镜像"与 HDMI 是同一个闭环里必须一起修的两件事。

---

## 3. 死锁与破局

```
simplefb 需要 fb 物理地址
  -> 地址是 hiboot 运行时动态分配的（SDK 源码确认无固定地址）
  -> 原计划：等 6.x 内核起来跑 ec6108-fbprobe 扫 VO 寄存器拿地址
  -> 6.x 起不来  ->  永远拿不到地址  ->  HDMI 永远不亮  ->  永远看不到日志
```

**破局**：这个地址在**能正常启动的社区系统里就能读出来**，不需要 6.x 先起来。
社区内核的私有 hifb 驱动注册了 `/dev/fb0`，通过 `FBIOGET_FSCREENINFO` ioctl
可直接拿到 `smem_start`（物理地址）、`smem_len`、`line_length`，配合
`FBIOGET_VSCREENINFO` 拿到分辨率、bpp 与各颜色分量偏移 → 直接映射成
simplefb 的 format 字符串。**不需要 `/dev/mem`，不需要知道寄存器偏移。**

所以"刷回社区包"不是为了看日志，而是**借它自带的私有驱动把显示硬件参数量出来**
—— 用户提出的"先用私有驱动拿到确定性"这个思路是对的，只是不必移植它，
直接用它当测量平台即可。

### 为什么不直接移植私有驱动

`hifb/VO/VDP/HDMI` 依赖整套 `MMZ/MPP` 框架与 4.4 内核 API，是数万行代码；
backport 到 6.3 还要适配 clock/reset/DT/dma-buf 等，且**同样需要真机调试**，
而真机此刻是盲的。成本与风险都远高于 simplefb 交接。

保留的后备（仅在 simplefb 前提被证伪时才动）：写一个几百行的**轻量
VO/HDMI 初始化驱动**，直接用社区内核量出的寄存器序列点亮 HDMI PHY 与 VO 层，
绕开整套 MPP —— 比移植私有栈小一个数量级。

---

## 4. 已完成的确定性修复（本专项代码）

| 改动 | 作用 |
|---|---|
| `console=tty0` 加入 cmdline | **关键缺陷**：原来只有 `console=ttyAMA0`（硬件无串口），即使 simplefb 注册成功内核消息也不会往 framebuffer 输出 |
| simplefb 模板参数化 | 宽高/stride/format/size 不再是写死的 1080p ARGB8888，可由 CI 输入覆盖 |
| `FB_WIDTH/HEIGHT/STRIDE/FORMAT/SIZE` → CI inputs | 拿到实测值后无需改代码即可出包 |
| `EXTRA_CMDLINE` 通道 | DTB cmdline 与 p2 运行时 env 一致，可带 `ramoops.*` 参数 |
| `CONFIG_PSTORE/PSTORE_RAM/PSTORE_CONSOLE` 编入内核 | 独立于 HDMI 的日志兜底：panic 写入保留内存，重启回社区系统可读 |
| `scripts/probe-framebuffer.sh` | 在社区系统上测量 framebuffer 全部参数，输出可直接填进 workflow_dispatch |
| `clk_ignore_unused`（已有） | 防止 6.x crg 时钟驱动关掉 VO/HDMI/VDP 时钟 |

---

## 5. 信心边界（诚实清单）

**有把握**：
- simplefb + fbcon 是主线标准机制，本内核 `CONFIG_FB_SIMPLE`、
  `CONFIG_FRAMEBUFFER_CONSOLE`、`CONFIG_VT` 全部已启用；`a8r8g8b8` 格式
  在 `SIMPLEFB_FORMATS` 表中确认存在
- hiboot 正常启动会配置 HDMI 且启动后持续扫描（§2 实证）
- `console=tty0` 是确定缺陷，已修
- `clk_ignore_unused` 已保障时钟不被关

**待实测（不能猜）**：
- `fb_base` 物理地址，以及**重启两次是否稳定**（hiboot 动态分配，可能每次变）
- 真实分辨率 / stride / 像素格式 / 显存大小
- VO 在内核启动后是否持续 scan-out（logo 一直挂着是强间接证据，非直接证明）

**风险与后备**：
- 若地址每次启动都变 → 静态 DTS 不可靠。后备：6.x 内核里加一个极小的
  platform driver，启动早期读 VO 层地址寄存器，用 `simplefb_platform_data`
  动态注册 simple-framebuffer（已核实主线 simplefb 支持 platform_data），
  不依赖静态地址
- 若 simplefb 根本不亮 → 用 §3 的轻量 VO/HDMI 初始化驱动
- 无论 HDMI 成败，**pstore** 都能把 panic 日志留下（地址待采集后填
  `ramoops.mem_address`，必须避开 framebuffer 区域）

---

## 6. 操作闭环（按顺序，一次触点只做一件事）

1. **恢复**：用 `TMP/community-restore/`（社区包解压，材料已备）重刷一次，
   回到能亮屏、能 SSH 的社区 Ubuntu。见 `TMP/恢复操作说明.txt`。
2. **测量**：在社区系统上运行
   `ssh root@192.168.3.232 'bash -s' < scripts/probe-framebuffer.sh | tee TMP/fb-report.txt`
   **重启一次再跑一遍**，对比两次 `fb_base`。把两次报告（尤其 §3/§4/§5/§6）发回。
3. **同时修刷机流程**：把 rootfs 镜像从 1 GiB 缩到 256~512 MiB
   （首启 `resize2fs` 扩容），`loadfiler` 补 `getinfo ddrfree`，
   `flashpartitionr` 长度同步缩小 —— 否则永远卡在刷机流程、`reset` 到不了、
   HDMI 参数再对也不会亮。见 `TMP/刷机失败排查说明.txt`。
4. **出包**：把实测 `fb_base/fb_width/fb_height/fb_stride/fb_format/fb_size`
   填进 `workflow_dispatch`；如需 pstore，在 `extra_cmdline` 填
   `ramoops.mem_address=<不与 fb 冲突的地址> ramoops.mem_size=0x100000`。
5. **验证**：刷我们的包，观察：
   - hiboot 刷完是否 ~1 分钟内 `reset`（说明 §6.3 已生效）
   - 重启后 HDMI 是否出现内核文字 / fbcon
   - 若仍黑屏，从社区系统读 `/sys/fs/pstore/` 或按保留地址 `dd /dev/mem` 取日志
6. 之后内核更新一律走 SSH `dd`（见 018 §7），不再按触点。

---

## 7. 与"日志"的关系（澄清）

刷回社区**看不到我们 6.x 内核的启动日志**（跑的是社区内核）。它的作用是：
(a) 量出显示硬件参数，(b) 提供一个能跑的系统来读 eMMC 现场与 pstore。
真正拿到我们内核的日志，靠的是本专项点亮 HDMI，或 pstore 兜底。

---

## 8. 参考

- `docs/017-debian-ci-kernel-port-plan.md` §待确认：fb_base 的原始计划
- `docs/018-debian-flash-guide.md` §6：clk_ignore_unused 与 fbprobe 原始思路
- `patches/kernel/simple-framebuffer.dtsi`：simplefb 节点模板
- `scripts/apply-dts-placeholders.py`：占位符替换
- `rootfs/usr/local/bin/ec6108-fbprobe`：6.x 内核起来后的 VO 寄存器交叉验证工具
