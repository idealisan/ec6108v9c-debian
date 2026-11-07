# 021 — HDMI 显示驱动移植专项（主线路线）

> 路线调整：`docs/020` 的 simple-framebuffer "搭便车"方案降级为备选。
> **主线路线改为驱动移植**：让 6.x 内核自己初始化 VO/HDMI，不依赖 hiboot 遗留状态、
> 不依赖社区内核、不需要探测寄存器或猜测显存地址。

---

## 1. 为什么改路线（社区系统实测结论）

社区 Ubuntu（4.4.35_ecoo）恢复后做了只读探索，得到的事实：

| 项目 | 实测值 / 现象 |
|---|---|
| 内核 | `4.4.35_ecoo_81082668`，私有显示驱动**内建**（`/proc/fb` = `0 hifb`） |
| 显示设备 | `/dev/fb0` (hifb)，`smem_start = 0x3c55c000`，`smem_len = 0xfd2000` |
| 几何 | 1920x1080，32bpp，ARGB8888，stride 7680，`virtual_size 1920,2160`（双缓冲） |
| `/proc/iomem` | `00000000-3fffffff : System RAM` —— **没有任何 reserved 显示区** |
| 用户态 | **没有任何显示相关程序/服务**，画面是内核/hiboot 留下的静态内容 |
| HDMI | dmesg `HDMI kernel event(no UserCallBack): HOTPLUG`，`HI_HDMI_kThread` 常态 `D/msleep` |
| 稳定性 | 多次重启后**屏幕有时亮有时不亮**；社区系统自己都不能保证输出 |

**关键推论**：

1. `0x3c55c000` 是社区内核 hifb 驱动**运行时从普通 RAM 分配**的图层缓冲
   （iomem 无 reserved 区、地址在 965 MiB 接近 DDR 顶端），
   **不是 hiboot 的 logo framebuffer**。把它填进我们的 simplefb DTS 是错的。
2. 社区系统没有用户态显示程序，HDMI 输出完全靠内核私有驱动 + HOTPLUG 回调，
   且重启后不稳定 → **它既不是可靠的测量平台，也证明"接管遗留显存"这条路脆弱**。
3. 想拿到确定性，必须让 6.x 内核**自己初始化 VO/HDMI** —— 即驱动移植。

### 探测过程的一次教训

`scripts/probe-framebuffer.sh` 曾用 `/dev/mem` mmap 扫描 VDP 寄存器页
(0xF9000000)，在社区 4.4 内核上触发
`Unhandled fault: external abort on non-linefetch`，并伴随 hifb ioctl 报错，
当次画面消失。**该段已从脚本中移除**；脚本现在只做 `/dev/fb0` 的标准 ioctl。
结论：不要在私有驱动的内核上直接扫寄存器页。

---

## 2. SDK 源码盘点（工作量有据可查）

来源：`zjkanjie/HiSTBLinuxV100R005C00SPC060`（`scripts/fetch-sdk.sh` 已在用），
commit `a9f05973129d738e175416dd4a91b2c264ffcdd4`。
通过 GitHub tree API 统计（快照在 `TMP/sdk-tree.json`）：

| 源码范围 | 文件数 (c/h) | 源码量 | 说明 |
|---|---|---|---|
| `source/msp/` 全部 | 4275 | 105 MiB | 完整 MPP 私有栈 |
| `source/msp/drv/vo/` | 627 | 16 MiB | VO/VDP |
| `source/msp/drv/hdmi/` | 223 | 6.6 MiB | HDMI TX |
| `source/msp/drv/hifb/` | 41 | 1.1 MiB | framebuffer |
| `source/kernel/linux-4.4.y.patch/drivers/hisilicon/` | 313 | 2.1 MiB | 4.4 内核驱动补丁 |
| `source/boot/product/driver/` (hiboot 驱动层) | 396 | 8 MiB | 含 pdm/disp/graphic |
| `source/boot/product/driver/graphic/` | 22 | 191 KiB | hiboot 图形栈 |
| `source/boot/product/driver/hdmi/` | 34 | 218 KiB | hiboot HDMI TX (`hdmi_1_4/`) |

早期"移植是数周工程、成本太高"的估计是在**没有盘点 SDK 之前**下的，偏悲观。
按上面的规模，两条移植路线都可行，只是代价不同。

---

## 3. 推荐方案：轻量 VO/HDMI 初始化驱动

不需要搬运整个 MPP 栈。目标是**点亮 HDMI 文字控制台**（看日志），不是视频解码/多图层。

**做法**：在 6.x 内核里新增一个 platform driver（`drivers/video/fbdev/` 或
`drivers/gpu/drm/` 下），启动早期完成：

1. `ioremap` VO/VDP/HDMI 寄存器区（基址在 SDK 头文件里）
2. 按 SDK 里的**硬编码显示时序**配置 DISP/VO：
   `source/boot/product/driver/pdm/drv_pdm.c` 的 `g_stDispTiming`
   （VFB/VBB/VACT/HFB、ClkPara0=0x912ccccc、ClkPara1=0x006d8157、
   `HI_UNF_DISP_INTF_TYPE_HDMI`、RGB888 24bit）
3. 初始化 HDMI TX / PHY：`source/boot/product/driver/hdmi/hdmi_1_4/`
   （`de.c` / `hdmitx.c` / `phy.c` / `infofrm.c`，共 218 KiB，裸机寄存器操作）
4. 自己分配一块显存（`alloc_pages` / `reserved-memory`），配置 GFX 层
   （地址/格式/stride/enabled），参考
   `source/boot/product/driver/graphic/gfx/hi_gfx_layer.c` 的
   `BOOT_GFX_DisplayLogoWithLayer` 流程
5. 注册 framebuffer：复用主线 `simplefb`（用 `simplefb_platform_data` +
   `IORESOURCE_MEM` 动态注册，已核实 6.3 的 `simplefb.c` 支持），或自写最小 fbdev
6. `console=tty0` + `fbcon`（已在 cmdline / config 中就绪）输出内核日志

**为什么这条最确定**：
- 显示时序/寄存器配置**静态来自 SDK 源码**，不需要探测、不依赖 hiboot 遗留状态
- 显存由内核自己分配，不存在"地址每次启动变化"的问题
- 代码量约几百到两千行，不依赖 4.4 内核 API，不受 MPP 用户态框架拖累
- hiboot 本来就能用这套配置点亮 logo，说明序列是验证过的

**依赖边界**：hiboot graphic 栈调用了 `HI_DISP_GetDisplayInfo` 等
`source/msp/drv/` 的 API，不能整目录照搬；但我们可以只取**寄存器写入序列**
（那些 `HI_DRV_*` 函数内部最终都是寄存器读写），避开 MPP 框架。

---

## 4. 备选方案：完整 MPP 私有栈移植

若后续需要的不只是文字控制台（视频解码、多图层、HDMI CEC 等），
则移植 `source/msp/drv/` 的 vo + hdmi + hifb + 4.4 内核补丁：约 24 MiB 源码、
4.4→6.3 的 API 适配（proc、DT、clk/reset、dma-buf、mm）、MMZ 内存管理。
代价显著高于 §3，且同样需要真机调试。**现阶段不取**。

用户提到此前有"从 Android 移植显示屏驱动到主线内核"的成功经验 —— 那类工作
与 §3 规模相当；本方案走的是同一条可控路径，只是源码取自 HiSTB SDK 的 hiboot
显示栈而非 Android vendor kernel。

---

## 5. 与已完成工作的关系（不浪费）

`docs/020` / 本轮已提交的改动仍然有用：

- `console=tty0`、fbcon 配置、字体、`CONFIG_FB_SIMPLE` / `FRAMEBUFFER_CONSOLE` / `VT`
  → 新驱动注册 framebuffer 后**直接复用**
- simplefb 几何参数化、`FB_*` / `EXTRA_CMDLINE` CI 输入 → 保留作为 §3 的
  framebuffer 注册参数来源
- `CONFIG_PSTORE*` + `ramoops.*` 通道 → 独立于 HDMI 的日志兜底，仍然保留
- `clk_ignore_unused` → 保留（新驱动应主动 `clk_get/enable` 所需时钟，
  但在那之前能防止 crg 关掉显示时钟）
- `scripts/probe-framebuffer.sh` → 降级为"了解社区系统"的参考工具，
  不再是取地址的关键路径

---

## 6. 验证路径（与刷机流程修复绑定）

驱动移植完成后要真机验证，就必须让刷机流程能走完 —— 这两件事是同一个闭环：

1. 修刷机流程：rootfs 镜像 1 GiB → 256~512 MiB（首启 `resize2fs` 扩容）、
   `loadfiler` 补 `getinfo ddrfree`、`flashpartitionr` 长度同步缩小。
   否则永远卡在刷机流程、不 `reset`、屏幕不亮（`docs/018` §10 / `TMP/刷机失败排查说明.txt`）。
2. 出包：CI 构建带新驱动的内核 + 缩小的 rootfs。
3. 刷机：观察 ~1 分钟 `reset`、重启后 HDMI 是否出现内核文字。
4. 若仍无画面：用 `ramoops` 保留地址读 pstore 日志，不依赖 HDMI。

之后内核更新一律走 SSH `dd`，不再按触点。

---

## 7. 待办清单

- [ ] 把 SDK 显示相关源码（`source/boot/product/driver/{graphic,hdmi,pdm}` +
      `source/msp/drv/vo|hdmi` 中寄存器定义）拉到项目内 `TMP/sdk-src/` 做逐文件分析
- [ ] 提取 VO/DISP/HDMI 寄存器基址与初始化序列，写成移植设计说明
- [ ] 实现 6.x platform driver 补丁（放进 `patches/kernel/`）
- [ ] 本地静态校验：`bash -n`、Kconfig/Makefile 挂接、DTB 编译
- [ ] CI 出包 + 真机验证（须与刷机流程修复一起）
- [ ] 若 §3 失败，评估 §4 或 pstore-only 路线

---

## 8. 参考

- `docs/020-hdmi-display-porting.md`：simplefb 路线（现为备选）与信心边界
- `docs/004-hiboot-vs-uboot-analysis.md` §hiboot 板级驱动：`cmd_display.c` /
  `BOOT_GFX_DisplayLogoWithLayer` 的线索来源
- `docs/002-mainline-kernel-debian-survey.md`：SDK 版本与"主线无 HDMI 驱动"结论
- `TMP/sdk-tree.json`：SDK 目录树快照（用于统计与定位源码）
- `TMP/fb-report-1.txt`：社区系统 framebuffer 采集报告
