# 023 — 原厂 recovery 显示机制逆向分析（对照参考）

> 目的：在刷机**之前**就确认我们的显示方案是对的，而不是刷完才知道。
> 对象：`backup_stock/p3_recovery.img.gz`（原厂 Android recovery，16 MiB boot.img）。
> 方法：离线解包 + 反汇编 + 与 HiSTB SDK 源码交叉验证。
> 结论先行：**原厂 recovery 走的是"内核自己初始化显示硬件 + fbdev 画字"，
> 但它同时证明了一件事 —— hiboot 画完 logo 后，VO 图层寄存器里确实留着
> 那块显存的信息，这正是我们 simplefb 交接方案的基础。**

---

## 1. boot.img 结构

| 字段 | 值 |
|---|---|
| magic | `ANDROID!`，header_version=0，page_size=2048 |
| kernel | 2,822,648 B @ 0x3e08000（uImage 包装，内含 xz 压缩的 zImage） |
| ramdisk | 1,309,209 B @ 0x4e00000（gzip） |
| cmdline | `console=ttyAMA0,115200 blkdevparts=mmcblk0:1M(fastboot),4M(bootargs),16M(recovery),...,-(userdata)` |

原厂 recovery 的分区表与社区的**完全不同**（recovery 16M、system 520M、userdata 剩余），
这是 Android 原厂布局，与我们刷 U 盘用的社区布局无关。

---

## 2. ramdisk 内容（决定用户态怎么画）

完整文件清单（52 项，节选）：

```
./init, ./init.rc, ./ueventd.rc, ./ueventd.bigfish.rc
./sbin/recovery        458,568 B  ← 显示相关的主体
./sbin/adbd  ./sbin/healthd
./res/images/font.png          ← 位图字体！
./res/images/erasing_text.png  ./res/images/installing_text.png
./res/images/progress_empty.png ./res/images/progress_fill.png
./res/images/icon_installing*.png ./res/images/indeterminate0*.png
./res/keys  ./sepolicy  ./seapp_contexts  ./property_contexts
```

`init.rc` 里**没有任何 surfaceflinger / minui 服务**：

```
service ueventd /sbin/ueventd
service recovery /sbin/recovery
service adbd /sbin/adb recovery
```

即：老式 Android recovery 的显示由 **`/sbin/recovery` 进程内的 RecoveryUI 直接画**，
不经过 surfaceflinger 合成。

`ueventd.rc` 里有 `/dev/graphics/* 0660 root graphics`，
说明设备节点是 **`/dev/graphics/fb0`**（不是 `/dev/fb0`）。

---

## 3. `/sbin/recovery` 的 fb 使用方式（关键证据）

strings 命中：

```
/dev/graphics/fb0
cannot open fb0
failed to get fb0 info
can't open /dev/tty0
```

→ recovery 通过 `open("/dev/graphics/fb0")` + `FBIOGET_FSCREENINFO/VSCREENINFO` 取几何，
再用 ioctl 往显存里 blit `res/images/*.png`（含 font.png）来画界面。
**它完全依赖内核已经注册好 `/dev/graphics/fb0`**，自己不碰寄存器。

`sepolicy` 里另有 `surfaceflinger` / `drmserver` / `drm_data_file` 策略项，
说明这套 SDK 的完整 Android 图形栈用的是 **DRM/KMS（drmserver）**，
而 recovery 走的是传统的 fbdev 路径（老 recovery 不依赖 KMS）。

---

## 4. 内核侧：谁初始化了 VO/HDMI

原厂 recovery 内核被 strip（`nm` 0 个符号），且其 payload 是 ARM NOP-sled 起始的
zImage，压缩流未能直接抽出 vmlinux。**因此内核侧改用 SDK 源码交叉验证** ——
原厂 recovery 用的就是这套 SDK 编译出的 4.4 内核，源码在 SDK 里。

### 4.1 显示栈分层（SDK 路径）

```
userspace:  /sbin/recovery (RecoveryUI)  ──fbdev──▶ /dev/graphics/fb0
userspace:  surfaceflinger/drmserver     ──KMS──▶   /dev/dri
kernel:     drivers/video/hifb (fbdev)  ──▶  source/msp/drv/hifb/
kernel:     VO/VDP 硬件控制             ──▶  source/msp/drv/vo/vdp_v4_0/
kernel:     HDMI TX/PHY                 ──▶  source/msp/drv/hdmi/hdmi_1_4/
bootloader: source/boot/product/driver/{graphic,hdmi}   ← hiboot 用的一套
```

### 4.2 VO 寄存器块（本次分析的关键收获）

`source/msp/drv/hifb/inc/drv_hifb_config.h`：

```c
#define CONFIG_VDP_REG_BASEADDR   (0xf8cc0000)
#define CONFIG_VDP_SIZE           0xfff0
#define CONFIG_HIFB_GFX_OFFSET     0x800     /* hi3798mv100 走 #else 分支 */
#define CONFIG_HIFB_GP_OFFSET      0x800
```

`source/common/drv/include/hi3798mv100/hi_reg_vdp.h` 定义 `S_VDP_REGS_TYPE`，
共 **605 个 u32 成员**（窗口 0x974 字节）。每个 union 正好 4 字节，
所以**成员偏移 = 4 × 序号**，可精确算出：

| 寄存器 | VO 基址 + 偏移 | 含义 |
|---|---|---|
| `VOCTRL` | +0x0000 | 层仲裁/全局控制 |
| `VP0_BK` | +0x0444 | 视频层背景色 |
| `G0_CTRL` | +0x048c | **图层 0 控制** |
| `G0_UPD` | +0x0490 | 更新标志 |
| **`G0_ADDR`** | **+0x0494** | **图层 0 显存物理地址**（`surface_addr` 全 32 位） |
| `G0_STRIDE` | +0x049c | 图层 0 stride（低 16 位） |
| `G0_IRESO` | +0x04a0 | 图层 0 输入分辨率：`iw[11:0]` 宽、`ih[23:12]` 高 |
| `G0_ALPHA` | +0x04e0 | alpha 混合 |
| `G0_PARAADDR` | +0x04b8 | 参数地址 |

**交叉验证**：SDK 的 `OPTM_VDP_GFX_SetLayerAddrEX()` 访问
`&pOptmVdpReg->G0_ADDR.u32 + layer * CONFIG_HIFB_GFX_OFFSET`
（`source/msp/drv/hifb/adp/src/drv_hifb_adp.c`），与上表偏移一致 ✓
（该 SoC 只有一个 GFX 图层，故只有 G0）。

### 4.3 hiboot 侧（bootloader）做过的初始化

`source/boot/product/driver/hdmi/hdmi_1_4/hdmi.c`：

```
HI_UNF_HDMI_Init()   → HW_ResetHDMITX(); SW_ResetHDMITX(); TX_PHY_PowerDown(TRUE)
HI_UNF_HDMI_Open()   → TX_PHY_PowerDown(FALSE)
                      → HDMI_Display(fmt, YCBCR444/RGB444)
HDMI_Display()       → GetSinkCapability(读 EDID!)
                      → UpdateTX_656 → SetIClk(0) → WakeUpHDMITX
                      → AVI InfoFrame / VIC(1920x1080P60=0x51,0xaa,...)
                      → TX_PHY_HighBandwidth / TX_PHY_SwingCtrl
                      → TX_SetHDMIMode(hdmi_dvi_mode) → TX_PHY_EnableHdmiOutput()
```

关键结论：
- **真正干活的是 `HI_UNF_HDMI_Open()` → `HDMI_Display()`**，
  `HI_UNF_HDMI_Start()` / `HI_DRV_HDMI_Init()` 是**空壳**（只打日志就返回成功）
- **显示时序来自 EDID**（`SinkCap.stPerferTiming`），不是硬编码常量；
  `drv_pdm.c` 里的 `g_stDispTiming`（1366x768、ClkPara0=0x912ccccc）只是 fallback
- hiboot 在 `PRODUCT_DisplayInit` → `HI_GFX_ShowLogo` 流程里配置 VO 图层并画 logo，
  **因此 G0_ADDR / G0_STRIDE / G0_IRESO 三个寄存器里留着 logo 帧缓冲的信息**

### 4.4 HDMI TX 寄存器（移植时可直接用）

`source/boot/product/driver/hdmi/hdmi_1_4/drv_reg_proc.h`，条件分支明确含
`CHIP_TYPE_hi3798mv100`：

```c
#define HDMI_TX_BASE_ADDR       0xf8ce0000L   /* SLV0 */
#define HDMI_TX_SLV1_ADDR_BASE  0xf8ce0400L
#define HDMI_TX_CEC_ADDR_BASE   0xf8ce0800L
#define HDMI_TX_PHY_ADDR        0xf8ce1800L
#define HDMI_REG_WRITE(addr,val) (*(volatile unsigned int *)(addr) = (val))
```

---

## 5. 与我们的方案的关系（决策依据）

### 5.1 原厂 recovery 证明的事

1. **硬件完全能显示文字** —— 原厂 recovery 用 4.4 内核 + hifb/VO/HDMI 私有驱动
   自初始化显示硬件，再由 userspace 经 `/dev/graphics/fb0` blit PNG 字模画出 UI。
2. **社区 Ubuntu 不显示文字 ≠ 这套硬件不支持** —— 社区内核同样内建 hifb、注册了
   `/dev/fb0`（实测 `smem_start=0x3c55c000`、1920x1080 ARGB8888、stride 7680），
   但**没有 fbcon、也没有用户态往 fb 画**，屏幕上只剩 hiboot 那张广告画面。
   → "驱动在" 与 "有输出" 是两件事。
3. **hiboot 确实配置了 VO 并画了 logo** —— 证据就是 §4.2 那三个寄存器。

### 5.2 由此确定的两阶段实现

**第一阶段（已实现，本仓库 `patches/kernel/hi3798mv100-hdmi-console.c`）**
"保留 hiboot 状态 + simplefb 交接"：
- 不重新初始化 VO/HDMI（会重置 bootloader 状态导致黑屏，postmarketOS 的教训）
- 读 `VO_G0_ADDR`(+0x494) / `VO_G0_STRIDE`(+0x49c) / `VO_G0_IRESO`(+0x4a0)
  拿到显存地址、stride、分辨率
- `memremap` 校验该地址确有像素内容
- 用 `simplefb_platform_data` 动态注册 `simple-framebuffer` device → fbcon 出字
- 兜底：寄存器读不到时扫 HDMI TX bank（类似用户态的 ec6108-fbprobe）

**第二阶段（若第一阶段在真机上找不到显存/不显示）**
"自己初始化显示硬件"，照搬 §4.3 的 SDK 序列：
`HDMI_Display()` 的 EDIC/HPD/TX_PHY/InfoFrame 序列 + VO 图层配置 +
自己分配显存 —— 即原厂 recovery 走的同一条路。
必要前提是移植 `source/msp/drv/{vo,hdmi}` 的 HAL 层
（`hi_reg_vdp.h` 已有全部寄存器定义，HAL 是裸寄存器读写，可直接改写成 6.x 驱动）。

### 5.3 仍需真机确认的点（诚实清单）

- hiboot 画 logo 时用的是 **G0（GFX 层）还是 GP/WBC 层**？
  若 logo 实际画在 GP0（`GP0_ADDR` 偏移 = `G0_ADDR` + `CONFIG_HIFB_GP_OFFSET`），
  第一阶段读 G0 会读不到，需要同时读 GP0。
- hiboot 是否写了 `G0_IRESO`（分辨率）？若为 0，驱动会回退到 1920x1080 默认值。
- logo 帧缓冲是否 4 KiB 对齐、是否落在 `DDR_START+1MiB .. DDR_END-8MiB` 之外
  （驱动里的合法区间判断据此设定）。
- VO 时钟是否被 6.x 的 crg 驱动关掉 —— `clk_ignore_unused` 已加，
  但若第二阶段要自己初始化，必须改为**主动 `clk_get/enable`**。

---

## 6. 可复现的分析工具（本仓库 TMP/，非提交产物）

| 文件 | 用途 |
|---|---|
| `TMP/recovery-tools/analyze_recovery.py` | 解 boot.img → 分离 kernel/ramdisk；列 ramdisk 文件树；dump init.rc/ueventd.rc；提取 recovery 的 fb 相关字符串 |
| `TMP/recovery-tools/extract_kernel.py` | 处理 boot.img → uImage → gzip/xz/lz4 多层包装，剥出内核 payload |
| `TMP/recovery-tools/vo_offsets.py` | 解析 `hi_reg_vdp.h` 的 `S_VDP_REGS_TYPE`，**算出任意 VO 寄存器的精确偏移** |
| `TMP/docker-build-check.sh` | 容器内交叉编译验证驱动（只读挂载内核树） |

`TMP/recovery-analysis.log` 是本轮完整输出。

---

## 7. 参考

- `docs/022-hdmi-driver-design.md`：驱动移植设计与两阶段方案
- `docs/021-hdmi-driver-porting.md`：路线决策与 SDK 盘点
- `docs/015-recovery-reverse-engineering.md`：原厂 `/sbin/recovery` 的签名链路分析（Android boot 侧）
- `docs/004-hiboot-vs-uboot-analysis.md`：hiboot 链式加载与显示初始化线索
- SDK：`zjkanjie/HiSTBLinuxV100R005C00SPC060` @ `a9f05973`
  - `source/common/drv/include/hi3798mv100/hi_reg_vdp.h`（VO 寄存器，10700 行）
  - `source/msp/drv/hifb/{inc,adp}/`（hifb HAL，3018+5155 行）
  - `source/boot/product/driver/hdmi/hdmi_1_4/`（hiboot HDMI TX）
  - `source/boot/product/driver/graphic/gfx/`（hiboot 图形栈）
