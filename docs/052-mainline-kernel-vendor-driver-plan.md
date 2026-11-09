# 052 — 方向调整（用户拍板）：6.3 主线内核 + backport 海思私有显示驱动

> 2026-11-09。用户原话（决策，纠正此前隐含约束）：
> 「我要的是主线内核的功能，我不想要安卓内核、不想要安卓下游的内核，
> 但我不要求一定是主线内核的驱动，我不管它驱动是什么样的，
> 只要它能够提供主线内核对普通应用程序的功能就可以了。」
> 「我们仿照 4.4 的做法去驱动设备、驱动显示器、驱动网卡，在 6.3 里工作，不就行了吗。」
>
> 本文是**补丁方案 + 打包方案**的正式落点。相关：docs/021（移植路线）、docs/027（原厂显示栈静态分析）、
> docs/044（6.3 网络已配齐）、docs/050（刷机程序）。研究员全量反汇编继续进行，不中断。

---

## 0. 决策与方向纠正

此前项目一直默认守着一个**并未由用户提出的隐含约束**："用主线内核 ⇒ 显示/网络驱动也必须是主线驱动
（simplefb 交接 + 猜 `fb_base`、主线 `hisi_femac`）"。这条窄路让我们卡了十几轮：simplefb 交接前提
（hiboot 遗留显存地址、跨次稳定）始终没坐实，8 个 `fb_base` 候选盲试。

用户拍板后，约束改为：**内核 = 6.3 主线（提供主线 ABI / 通用子系统 / 非安卓下游内核）；
驱动可以是 backport 的海思私有栈。** 这正是 postmarketOS 的标准做法
（`mainline kernel + downstream drivers`，docs/025 §1.2）。

**关键判断（[观察]，已核实）**：6.3 主线内核其实**已经具备**绝大部分"主线内核对普通应用的功能"：
- 网卡 `CONFIG_HISI_FEMAC=y` + `hisi-femac-v2` DTS 节点、MDIO/PHY/时钟/复位/systemd-networkd/DHCP
  逐项齐全，无确定缺口（docs/044 §2/§3）。→ **网卡不需要私有 `hieth`**，主线 `hisi_femac` 即可，
  这也是用户"仿照 4.4 驱动网卡"在 6.3 里的等价物（同一颗 FEMAC，不同驱动实现）。
- MMC / USB / I2C / CRG 时钟 / 主线 DRM 框架都在（hi3798mv100.dtsi）。
- **真正缺的只有显示输出栈**（VO/VDP/HDMI TX/hifb）。所以新方案的工程量集中在显示，不是整机重写。

---

## 1. 前提修正（必须知道，否则方案建在错地基上）

用户说"我们肯定是有 3.10 和 4.4 的 DTS，照抄即可"。核实结果：
- **原厂 Android 3.10 内核是 ATAG，无设备树**（docs/005 附录「Android 4.4 + ATAG，无设备树」；
  docs/027 §3.1 p11 boot.img `dt_size=0`、无追加 DTB）。备份里**没有**可照抄的下游 DTS 文件。
- 6.3 主线内核**已有**板级 DTS：`third_party/linux-hi3798mv100/arch/arm/boot/dts/hi3798mv100.dtsi`
  和 `hi3798mv100-ec6108v9c.dts`（主线 binding）。

→ 所以"仿照 4.4 做法"= 复刻 **寄存器初始化序列 + board 显示参数（baseparam/pqparam 里的
`BASE_TABLE_DISP0/1`、`TIMING_*`、接口使能位）+ 私有驱动的硬件配置语义**，用主线 DTS binding
（`compatible`、`reg`、`clocks`、`resets`）重写，**不是搬 DTS 文件**。

**私有栈形态（docs/027 §4）**：显示驱动编进 3.10 内核（`/lib/modules/` 16 个 `.ko` 全是
WiFi/USB/蓝牙/文件系统，零个显示模块）→ 不存在"拷一个 .ko 点亮屏幕"。专有 Android HAL 是用户态
`.so`（gralloc/hwcomposer/hidisplay/libhi_msp），按 pmOS 结论不可在 mainline 直接复用。
依赖 MMZ 私有内存管理、`/proc/msp/*`、`/dev/mmz_userdev`。时序运行时从 sink EDID 读
（docs/027 §4.7 baseparam 里 `TIMING_*` 全 0、EDID 缓存全 0）。

---

## 2. 补丁方案（patches/）

### 2.1 现状（simplefb 交接路线，降级为 legacy / 诊断用，不删）
`scripts/build-kernel.sh` 应用：
- `0001-ec6108v9c-dts-simplefb-tsensor.patch`（chosen bootargs + memory@0 + `__FB_BLOCK__` 占位）
- `0002-thermal-kconfig-makefile.patch`
- `0003-hdmi-console-kconfig-makefile.patch`
- 复制 `hi3798mv100_tsensor.c`、`hi3798mv100-hdmi-console.c`（simplefb 交接，运行时读 VO G0_ADDR）
- `configs/kernel/ec6108v9c.config`：`FB_SIMPLE` / `FRAMEBUFFER_CONSOLE` / `VT` / `hisi_femac` 片段
- `apply-dts-placeholders.py` 注入 `simple-framebuffer.dtsi` + `ramoops.dtsi`

### 2.2 新增：`patches/vendor-display/`（backport 海思私有显示栈，本期方向）
按 docs/021 §3「轻量 VO/HDMI 初始化驱动」路线（不选 §4 完整 MPP 24 MiB 栈）：
- **源码来源**（HiSTB SDK `TMP/sdk-src/`）：
  - `source/boot/product/driver/pdm/drv_pdm.c`（`g_stDispTiming`、`ClkPara0/1` 硬编码时序）
  - `source/boot/product/driver/graphic/gfx/`（`BOOT_GFX_DisplayLogoWithLayer` / `HI_GFX_ShowLogo`
    的图层配置：G0_ADDR / stride / IRESO）。只取**寄存器写入序列**，不整目录照搬（避开 MPP 框架）。
  - `source/boot/product/driver/hdmi/hdmi_1_4/`（HDMI TX/PHY 初始化，`de.c`/`hdmitx.c`/`phy.c`）。
  - `source/msp/drv/{vo,hifb}` 作交叉验证（寄存器结构体定义 hi_reg_vdp.h）。
- **4.4 → 6.3 API 适配**（docs/021 §3/§4）：SDK MMIO → 主线 `ioremap + readl/writel`；
  clk/reset → 主线 `crg` provider（`COMMON_CLK_HI3798`）；显存 → `alloc_pages` / `reserved-memory`
  或复用 MMZ 语义；注册 → 主线 `fbdev` 或 `drivers/gpu/drm/hisilicon/` DRM。
- **挂载点**：`drivers/video/fbdev/`（或 `drivers/gpu/drm/hisilicon/`）的 Kconfig/Makefile patch。
- **依赖（硬）**：`HDMI_Display()` / `TX_PHY_*` / `PRODUCT_DisplayInit` 的**精确寄存器写入序列**
  = 研究员全量反汇编 `p01_fastboot.img` + `p11 vmlinux` 的产出（`TMP/stock-rom-research/full-disasm/`，
  进行中，不中断）。docs/025 §2.2 铁律：初始化序列逐字节来自原厂资产，不手写猜。

清单与适配细节见 `patches/vendor-display/PORTING.md`。

### 2.3 网卡
保持主线 `hisi_femac`（`CONFIG_HISI_FEMAC=y` + `hisilicon,hisi-femac-v2` DTS 节点）。不改。
docs/044 已确认静态配置层齐全；"无 IP"更可能是内核没起来（见 §5）。

---

## 3. 打包方案（workflow + 脚本）

- `.github/workflows/build-release.yml`：
  - 新增 `display_driver` input（`simplefb`（默认，保持现状可用）/ `vendor-backport`（新方案））。
  - `fb_base`/`fb_width`/… 描述标注为 **legacy simplefb 交接（诊断/候选试探）**。
  - `build-kernel` job 把 `DISPLAY_DRIVER` 传给 `scripts/build-kernel.sh`。
- `scripts/build-kernel.sh`：按 `DISPLAY_DRIVER` 分支：
  - `simplefb`（默认）：现有逻辑完全不变 → CI 默认路径不破坏。
  - `vendor-backport`：应用 `patches/vendor-display/` 补丁、复制 backport 驱动、跳过
    `apply-dts-placeholders.py` 的 simplefb 占位（chosen bootargs / memory@0 / ramoops 仍保留）。
    驱动未就绪时明确 fail-fast 并指向 `docs/052` 与 `PORTING.md`，不假装完成。
- **打出的刷机包结构不变**：`hi_kernel.bin`（换成带新驱动的 6.3 内核）+ Debian rootfs sparse
  + p2 env + p5 logo；`make-community-flash-package.sh` / recovery-flasher 打包机制不变。
- 产物仍是 `mv100-mdmo1g-*-usb-flash-*.zip`，release `build-$STAMP`。

---

## 4. 阶段（诚实标注依赖，不跳步）

1. 研究员全量反汇编 `p01_fastboot` + `vmlinux` → 提取寄存器初始化序列、交接值（进行中，不中断）。
2. 按 §2.2 + `PORTING.md` 写 backport 驱动 + Kconfig/Makefile 补丁。
3. CI `display_driver=vendor-backport` 编译 6.3 + 新驱动，产出刷机包。
4. 真机短接刷、断电开机判据（§5）。

这是数周级驱动移植 + 真机调试（docs/021 §4、docs/025 §1.2「跨大版本 backport 接近重写」），
**不是改个打包脚本就能立刻点亮**。本文先把方案、补丁结构、打包接线定死，等序列到位即可落地。

---

## 5. 判据与更靠前的前置（不能跳过）

docs/044 §0 / docs/024 §6 / docs/026 §0 一致结论：主线 6.3「无显示 + 无 IP」同时出现，
最简洁一致的解仍是**内核没启动到 userspace**。所以：
- **无论用哪套驱动，内核得先起来**。内核里已内置绿带 boot marker（`hi3798mv100-hdmi-console.c`），
  只要跑到 `subsys_initcall` 就会在屏幕顶部画纯绿粗带，不需要网络/TTY/串口/pstore。
- 试包时盯绿带：出现 = 内核起来了（新显示驱动才有意义）；始终只有 logo + 浅蓝细线 = 内核没起来，
  先查启动链（DTB `/chosen bootargs` + `mem=1G` + `/memory@0` + uImage load/entry + early panic）。
  研究员全量反汇编也附带核对 6.x 启动链是否与原厂 hiboot 交接约定冲突。
- 静态反汇编不能判定"内核起没起"，必须真机信号。真机为准，静态推断不作为成功依据。

---

## 6. 合规
- 本机只做轻量校验（bash -n / YAML 解析 / 文档），不构建 rootfs / 系统镜像（CI only）。
- 不删文件、不清理 git；提交显式 `git add <具体路径>`，提交后 `git show --stat` 核对。
- 不含本机绝对路径 / 用户名 / IP / 凭据。
