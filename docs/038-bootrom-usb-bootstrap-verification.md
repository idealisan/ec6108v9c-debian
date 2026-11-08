# 038 — BootROM USB bootstrap 假设的证实/证伪（固件静态 + 文档级证据）

> 2026-11-08。承接 `docs/037 §4.1`：该节列出两个冲突的「短接兜底」模型，并把
> 「写 p1 不可逆」列为 NO-GO 的否决项之一，但明确留了 `[存疑]`——唯一可能推翻它的是
> **模型 B**：`USB_BOOT` 短接时 BootROM 从 U 盘 FAT32 根目录加载 `fastboot.bin` 到 RAM 执行。
> 本轮专职证实/证伪这一条，不改动 `docs/035`（已由主会话提交 `fe0ee81`）、不改动 `docs/037`。

---

## 0. 结论先行

| # | 问题 | 结论 | 标注 |
|---|---|---|---|
| 1 | **短接触点的检测者是谁**？ | 二进制里能定位到的「检测」全部在 **hiboot（被加载镜像）侧**：它读 BootROM 预置的 start-mode / bootstrap-type 寄存器，据此从 U 盘读 `bootargs.bin` / `recovery.img`。`invalid vadc id!` 是 **DISP/PDM 显示参数校验串**（与按键/短接无关），`boot from USB device` 是 **`usbboot` 命令帮助文本**（legacy U-Boot USB 分区启动，非 BootROM bootstrap）。**纯二进制不能裁决 BootROM 取码来源**；范围内未检索到任何「从 U 盘 FAT32 加载名为 `fastboot.bin` 的引导镜像」的代码。 | [观察] + [存疑] |
| 2 | **顶层 `fastboot.bin` 的角色**？ | 顶层与内层**功能同构**：启动路径 / USB 加载 / bootargs 处理函数结构全等，差异仅版本串导致的 rodata 4–8 字节偏移与指针字面量重定位（`usbboot` 112/112 指令相同、DOWN-check 8/8 相同）。它**不是内容上「专门准备」的 bootstrap 镜像**；但它具备文档要求的**唯一决定性属性：文件名 `fastboot.bin` + 位于 U 盘 FAT32 根目录**，且同根目录有 CRC 校验通过的 `bootargs.bin`，其 `bootcmd` 第一步会把内层 `mv100/fastboot.bin` 重新写进 p1。→ **顶层那份就是 BootROM USB bootstrap 的引导镜像（靠名字/位置，不靠内容）**，`docs/001 §7.3`「救砖/参考、无主」的疑点由此解释，**间接支持模型 B**。 | [观察] + [推断] |
| 3 | **BootROM 取码来源能否从二进制判定**？ | **不能**。BootROM 是芯片掩膜 ROM，不在我们任何镜像里；纯静态反汇编 hiboot 无法直接证明/证伪 BootROM 行为。只能给「支持 B / 支持 A」的间接证据清单（§3），逐条标注。本文**不编造 BootROM 代码或寄存器**。 | [观察] + [未知] |
| 4 | **histb 官方文档原文出处**？ | **已核实，给文档级证据**：`software/bootrom/bootstrap.html` 明确「`USB_BOOT` 短接 GND → U 盘 FAT32 根放 `fastboot.bin` → bootrom 从 U 盘加载 bootloader 到 RAM」，并给出「找不到 `fastboot.bin` 才回退 eMMC/NAND」的启动日志；`appendix/boards/ec6108v9c.html` 标 **USB_BOOT = J16**；`software/vendor/fastboot.html` 给 fastboot 层的 U 盘 `bootargs.bin`/`recovery.img` 序列。三页均给出可复现的 GitHub RST 源。`docs/025 §5.5.2` 转述与原文一致。性质：**第三方社区文档（histb teams），非海思官方数据手册、非本机运行时实证**。 | [观察] |
| — | **go/no-go 更新** | `docs/037 §4.1` 的**否决项「写 p1 破坏短接兜底 → 不可逆」可被推翻**（模型 B 文档级证实 + J16 板级页面 + 社区包结构 + 二进制首阶段字符串四方互证），**改 p1 的前置评估可重启**；但 `docs/037 §4.3` 的其余门槛（显示函数体未定位、`go` 路径关闭、YZC/CRC 存疑、Live-USB 零写入验证未做）**全部仍成立**，故**整体 NO-GO 暂不解除**，「可重启评估」≠「可立即写 p1」。 | [推断] |

**判定一句话**：**模型 A / B 并非互斥，而是同一 `USB_BOOT` 引脚的不同电平状态**（§5.1）；短接（刷机/救砖）态走**模型 B**，这一态由文档级证据裁定为 B。

---

## 1. 对象、工具、方法（复现基线）

**[观察]** 本轮只读分析 4 份 hiboot 镜像，均带 `YZCv1.1.0 @0x3d` 私有头、`190800ea` 异常向量表、链接基址 `BASE = 0x00C00000`（`docs/031 §1.2`、`docs/036 §4.1` 已验证）：

| 对象 | 路径（仓库内相对） | 大小 | SHA-256 | 角色 |
|---|---|---|---|---|
| 原厂 fastboot | `backup_stock/fastboot.img` | 1,048,576 B | `bac0be9ff5926de1c813668216977c85e1903ceb3e69b83e5a7ffb2156b0c073` | 原厂 p1 分区备份（1 MiB padded） |
| 社区 U 盘**顶层** | `TMP/community-restore/fastboot.bin` | 539,264 B | `fd5b4ac6ce4d50e8a127957dc86a2d2fa503d150db2abca014033ad4e7de7f0b` | 顶层，不被任何 `loadfileX` 引用 |
| 社区**内层** | `TMP/community-restore/mv100/fastboot.bin` | 539,272 B | `3bded87f15c1ebd686f39c23570650ac2b53a97815b592a0130b06fe2ce954ae` | `flashfastboot` 写进 p1，本机实测可引导 |
| 本机构建 | `build/verify2/fastboot-burn.bin` | 519,468 B | `d5bb8272164425e5469519338adeb7bfe996f1befec0cce24f681f2493b211f1` | 本机构建，无真机引导记录 |

工具：**capstone 5.0.7**（主，`Cs(CS_ARCH_ARM, CS_MODE_ARM|CS_MODE_LITTLE_ENDIAN)`，`skipdata=True` 全文件覆盖）与 **radare2 6.2.4**（`r2 -a arm -b 32 -m 0x00C00000`，独立 oracle，`pd`/`pxw`/`ps` 互验）。三份版本串分别为 `3.3.0_ecoo_81100468`（2022-10 顶层）、`3.3.0_ecoo_81082668-dirty`（2025-08 内层）、`3.3.0-00786`（2016-08 原厂）；厂商构建机标识按 `docs/037 §5` 惯例省略。

方法：全文件 `ldr [pc,#imm]` 字面量池扫描 + 32 位指针字扫描 + `bl` 调用图 + 函数序言判定 + `movw/movt`/`adr` 计算 + 双镜像逐字节 diff 与指令结构比对；文档核实走公开网络页面与其 RST 源。临时产物全在 `TMP/b038/`（gitignored）。

---

## 2. Q1 — 短接触点的检测者是谁

### 2.1 三个「线索串」的真实身份（纠正两处预设）

**[观察]** 对 4 份镜像做字符串定位 + 字面量/指针交叉引用，得到：

| 串 | 位置（社区顶层，VA） | 引用方式 | 真实身份 |
|---|---|---|---|
| `invalid vadc id!` | `0x00c714f4` | 指针字 0 命中、字面量 0 命中（范围内未检索到） | 位于 **DISP/PDM 显示参数串簇**内（`DISP%d PDM Param:`、`HDMI ID=%d`、`Y=%d, Pb=%d, Pr=%d`、`CVBS=%d`、`invalid color param!`、`invalid aspect ratio param!`、`DISP get param failed!`、`DISP0 Param invalid!`），紧邻 `BASE_KEY_HDMI` / `BASE_KEY_YPBPR` / `BASE_KEY_CVBS` / `BASE_KEY_ASPECT` / `BASE_KEY_TIMING_*` 参数键。**是显示参数校验错误串，不是按键 ADC / 短接检测**。 |
| `boot from USB device` | `0x00c7abc6` | 指针字 @`0x80624` = `cmd_tbl_s` 记录的 `usage` 字段 | `usbboot` 命令的 **usage 文本**。 |
| `usbboot` | `0x00c7abbe` | 指针字 @`0x80614` = `cmd_tbl_s` 记录的 `name` 字段 | 真实 U-Boot 命令，处理函数 `0x00c10fd8`。 |

→ **[观察]** 「VADC = 按键 ADC 检测线索」「`boot from USB device` = 启动决策日志」两处预设，**在本轮范围内未获二进制支持**。全文件对 `key`/`keypad`/`button`/`short`/`USB_BOOT`/`J16`/`bootstrap`/`vadc` 的宽匹配里，与「短接/按键」相关的只有 U-Boot 通用 `bootdelaykey` / `bootstopkey` / `Press Ctrl+C to stop autoboot`（串口 autoboot 停止键），**范围内未检索到**任何「短接触点 / 按键组合 / VADC 按键」检测串。

### 2.2 `usbboot` 命令体的实证（radare2 + capstone 互验）

**[观察]** `cmd_tbl_s` 记录 @`0x00c80614`（radare2 `pxw` 与 capstone 指针扫描一致）：

```
0x00c80614  0x00c7abbe( "usbboot" )  0x00000003(maxargs)  0x00000001(repeatable)  0x00c10fd8(cmd)
0x00c80624  0x00c7abc6( "boot from USB device" )  0x00c7abdb(help)
```

反汇编 `do_usbboot @0x00c10fd8`：读 `bootdevice` env → `0xc1a6d0` 取存储设备 → 解析 `dev:part` → `0xc67560` 读分区信息 → 校验分区类型串为 `"U-Boot"` / `"PPCBoot"`，否则打印 `** Invalid partition type "%.32s" (expect "U-Boot")`；配套串 `Loading from USB device %d, partition %d: Name: %.32s Type: %.32s`、`error reading partinfo...try to boot raw`。

→ **[观察]** `usbboot` 是 **legacy U-Boot 的「从 USB 大容量存储的带类型分区启动」命令**，由用户/脚本显式调用，**要求 hiboot 已在运行**，且读的是**分区表**而非 FAT32 文件名 `fastboot.bin`。它与 BootROM USB bootstrap 不是同一机制。

### 2.3 二进制里真实存在的「启动模式」检测（全部在 hiboot 侧）

**[观察]** 全文件反汇编定位到三处读硬件状态寄存器的代码（以下 VA 以社区顶层为准，4 份镜像结构同构）：

1. **首阶段 start-mode 分发**（`0x00c02108`，位于镜像前 `0x3000` 字节的首阶段代码，非 BootROM）：
   ```
   0x00c02108  ldr r0, [pc,#..]  ; pool = 0xf8a20000
   0x00c0210c  ldr r0, [r0]
   0x00c02110  lsr r6, r0, #9
   0x00c02114  and r6, r6, #3     ; 取 2-bit start mode
   ...  cmp r6,#3 → [0xf80000bc]=3 → bl 0xc02b98
        cmp r6,#2 → [0xf80000bc]=2 → bl 0xc02d54
        其它      → b  0xc024d0  ("*** Not support current start mode")
   ```
   `0xc02b98` / `0xc02d54` 为 `0xf9830000` 控制器 / DDR 时钟初始化序列（不同 start mode 的板级初始化），**不是**「从 U 盘取码」。

2. **DOWN 魔数检查**（`0x00c0c3e0`）：
   ```
   0x00c0c3e0  mov  r3, #0xf8000000
   0x00c0c3e4  ldr  r0, [r3, #0xb0]
   0x00c0c3e8  ldr  r3, [pc,#0xc]  ; pool @0xc0c3fc = 0x444f574e
   0x00c0c3ec  sub  r0, r0, r3
   0x00c0c3f0  clz  r0, r0
   0x00c0c3f4  lsr  r0, r0, #5     ; 相等返回 1，否则 0
   ```
   `0x444f574e` 为 4 字节魔数（字节 `4e 57 4f 44`；MSB-first 读作 `DOWN`，LSB-first 读作 `NWOD`）。**[推断]** 主决策恰在该魔数命中时才转入 U 盘 `bootargs.bin` 分支，故它很可能标记「`USB_BOOT` 被拉低 / 进入 bootstrap」态；「download」之名仅来自下游 `start download process.` 串，**非定论**。

3. **bootstrap-type 门控**（`0x00c0c698` 与主决策 `0x00c13ff8`）：
   ```
   0x00c0c698  mov  r3, #0xf8000000
   0x00c0c69c  ldr  r0, [r3, #0x88]
   0x00c0c6a0  cmp  r0, #3
   0x00c0c6a4  movne r0, #0        ; 只有 ==3 才返回 1
   ```
   主决策 `0x00c13ff8`：先 `bl 0xc0c3e0`（DOWN 检查，命中返回 1）→ **命中时** `bl 0xc0c698` → **仅当 `[0xf8000088]==3` 才 `bl 0xc0c29c` 去加载 U 盘 `bootargs.bin`**；未命中则转 `0xc14084`（另一路 env 载入），门控不满足则 `Using default environment`。另 `0x00c0c400`「start download process.」读同一寄存器 `[0xf8000088]`，`cmp #1 → bl 0xc0c0e0`（下载处理），`cmp #3 → 跳过`，其它打印 `not supported bootstrap type: %d`。

**[观察]** U 盘 FAT32 读取路径（与 `docs/036 §4.1` 实证吻合）：
- `0x00c0c29c`：USB 探测 `0xc19b98` → FAT 查找 `0xc19bd0("bootargs.bin")` → `fatload 0xc19cf4` 到 `0x1000000` → CRC32 `0xc5be68` → 置「U 盘 env 有效」标志。
- `0x00c0c344`：FAT 查找 + `fatload` 任意镜像名 → 拼 `bootm 0x%x` → 执行命令；`0x00c0c3c0` 以 `"recovery.img"` 调它。
- `0x00c0c230`：`recoverybootargs` env → 设为 `bootargs`。

**[观察]** `fastboot.bin` 字面量在 **4 份镜像中均为 0 命中**（"范围内未检索到"）。即：**被加载镜像里没有任何代码按文件名从 U 盘 FAT32 加载一份 bootloader**。hiboot 从 U 盘 FAT32 读的只有**环境变量文件** `bootargs.bin` 与**内核镜像** `recovery.img`。

### 2.4 Q1 判定

**[观察]** 二进制呈现的是一条完整的 **hiboot 侧**链：读 BootROM 预置的 start-mode / bootstrap-type 寄存器 → 条件满足才从 U 盘读 `bootargs.bin` / `recovery.img` → 跑 `bootcmd`。这与模型 A 描述的「p1 hiboot 读 U 盘 bootargs」行为一致，也与 `docs/036 §4.1` 的实证一致。

**[存疑] 边界**：模型 A / B 的**真正分歧点是「BootROM 从哪里取第一条指令」**，而 BootROM 掩膜 ROM **不在任何镜像内**（§3）。因此在纯二进制范围内：
- 不能因为「hiboot 里有 U 盘读取逻辑」就判模型 A——模型 B 下 U 盘那份 `fastboot.bin` 是**同一份镜像**，同样带这段代码；
- 也不能因为「没找到 `fastboot.bin` 加载代码」就判模型 B 成立——那段代码本就应在 BootROM 里。

→ **Q1 结论**：短接引脚的**采样在 BootROM 层**（hiboot 读的是预置寄存器而非自己采样 GPIO，[推断]）；二进制里能定位到的**检测/反应逻辑全在 hiboot 侧**；`invalid vadc id!` / `usbboot` / `boot from USB device` 三个线索**均不构成短接检测证据**。**纯二进制判定 = [存疑]（倾向 A 的行为链，但 B 无法从二进制证实或证伪）**；BootROM 层的裁决由 §4 的文档级证据给出。

---

## 3. Q2 — 顶层 `fastboot.bin` 的角色

### 3.1 双镜像 diff 实证

**[观察]** 顶层 `fd5b4ac6…`(539,264 B) vs 内层 `3bded87f…`(539,272 B)：首差异 @`0x2054`，公共区间共 **126,498 字节不同**，尾部多 8 字节；但**唯一差异字符串各仅 3 条**，全是版本/构建日期（顶层 `3.3.0_ecoo_81100468` / 2022-10，内层 `3.3.0_ecoo_81082668-dirty` / 2025-08）加一条无意义短串。**首差异本身很说明问题**：@`0x2054` 是首阶段重定位代码里的一个长度字面量，顶层为 `0x00c83a80`（`0x83a80` = 539,264 = **顶层镜像自身大小**），内层为 `0x00c83a88`（`0x83a88` = 539,272 = **内层镜像自身大小**），正好差那 8 字节。分区匹配显示：前 `0x10000` 区域 99% 相同；rodata 区整体 **+4 字节**位移、命令表区 **+8 字节**位移——即版本串变长把后续 rodata 与指针字面量整体推后。

**[观察]** 决定性函数逐指令结构比对（VA 相同、`0x00c7xxxx` 指针立即数掩码后比较）：

| 函数 | VA | 结构相同指令 | 差异 |
|---|---|---|---|
| `usbboot` 命令体 | `0x00c10fd8..0x00c11198` | **112 / 112** | 无 |
| DOWN 魔数检查 | `0x00c0c3e0..0x00c0c400` | **8 / 8** | 无 |
| start download | `0x00c0c400..0x00c0c464` | 23 / 25 | 2 条在字面量池（指向位移后的串） |
| `bootargs.bin` 加载 | `0x00c0c29c..0x00c0c344` | 40 / 42 | 2 条在字面量池 |
| `recoverybootargs` | `0x00c0c230..0x00c0c29c` | 24 / 27 | 3 条在字面量池 |
| `recovery.img` 加载 | `0x00c0c3c0..0x00c0c3e0` | 7 / 8 | 1 条在字面量池 |

→ **[观察]** 差异**不涉及启动路径 / USB 加载 / bootargs 处理的任何功能改变**；`YZCv1.1.0` 头、`Reg Version: v1.1.0`、`Relocate Boot to DDR` / `Jump to DDR` / `System startup` / `*** Not support current start mode` / `emmc: timeout` 首阶段串、start-mode 分发代码块 `0x206c..0x2200` 均**逐字节相同**。

### 3.2 但「名字 + 位置」才是决定性属性

**[观察]** 社区包 U 盘根目录只有三项：`fastboot.bin`(539,264 B)、`bootargs.bin`(65,536 B)、`mv100/`。解析 `bootargs.bin`：CRC32 头 `0x1888597E` 计算一致、`sector size 0x10000`、`bootdelay=0`、`verify=n`、`stdin/stdout/stderr=serial`，`bootcmd` 为 `run flashfastboot; run flashbootargs; ...; reset`，其中
`loadfilef=fatload usb 0 0x1000000 mv100/fastboot.bin`、`flashpartitionf=mmc write 0x0 0x1000000 0x0 0x0440`、`flashfastboot=run loadfilef flashpartitionf`。

**[推断]** 这份根布局与 §4 文档要求**逐项吻合**：`bootstrap.html` 要「U 盘 FAT32 根放一个名为 `fastboot.bin` 的 bootloader」，`fastboot.html` 要「USB_BOOT 拉低时 fastboot 读 U 盘根的 `bootargs.bin`（U-Boot env，sector 0x10000）」。顶层 `fastboot.bin` 此前在 `docs/001 §7.3` 被标为「救砖/参考、无 `loadfileX` 引用」而**无主**——文档级证据给了它确定的角色：**BootROM USB bootstrap 的 stage-0 引导镜像**。它不需要内容上「专门准备」，因为按文档 BootROM 才做取码，任何一份合法 hiboot 均可；其决定性属性是**文件名 + 根目录位置**。

**[推断]** 更进一步：`bootcmd` 第一步 `flashfastboot` 会把内层 `mv100/fastboot.bin` 重新写进 p1。于是「短接 + 这份 U 盘」= BootROM 从 U 盘取 `fastboot.bin` → fastboot 读 U 盘 `bootargs.bin` → 用 `mv100/fastboot.bin` 重写 p1 → `reset`。**这正好是写坏 p1 之后的自修复路径**，说明包作者本来就把顶层 `fastboot.bin` 当作与 p1 内容解耦的救援入口。

→ **Q2 结论**：顶层那份**不是内容上专门准备的 bootstrap 镜像**（功能代码与内层结构全等），**但就是 BootROM USB bootstrap 的引导镜像**（靠名字/位置），且其 `bootcmd` 承担 p1 自修复。**间接支持模型 B**，并直接给出救援物料。

---

## 4. Q3 — BootROM 取码来源能否从二进制判定

**[观察]** BootROM 是 hi3798mv100 芯片内**掩膜 ROM**，不是任何分区镜像的组成部分。本轮 4 份对象全部是 **fastboot / hiboot（U-Boot 派生）**镜像，含 `YZC` 私有头与 DDR 寄存器表，被 BootROM 加载到 `0x00C00000` 执行。`docs/004 §2.1`、`docs/004 §6` 亦记「BootROM 直接从 eMMC LBA0 加载到 `0x00C00000`」「YZC 私有头格式未完全逆向」。

→ **[观察] 硬边界**：**纯静态反汇编 hiboot 无法直接证明或证伪 BootROM 的取码来源**。本文不编造 BootROM 代码、不臆测 BootROM 寄存器。下面只列**间接**证据，逐条标注，且「0 命中」一律读作「在本轮对象/扫描方式/范围内未检索到」。

**支持模型 B（BootROM 从 U 盘 FAT32 根取 `fastboot.bin`）的间接证据**

| # | 证据 | 标注 |
|---|---|---|
| B1 | `bootstrap.html` 原文明确描述该机制并给出 `Entry usb bootstrap / Udisk(1)` 与 `No found fastboot.bin in host:1/2 → eMMC` 两段启动日志（§5.2）。 | 文档级证据 [观察] |
| B2 | `ec6108v9c.html` 把 **USB_BOOT = J16（near power switch）** 直接链接到 `bootstrap.html#usb-boot`；与本项目「短接触点」是同一物。 | 文档级证据 [观察] |
| B3 | 社区包 U 盘 FAT32 根**恰好**有 `fastboot.bin` + 合规 `bootargs.bin`，文件名/位置与 B1/B2 要求逐项吻合；该文件不被任何 `loadfileX` 引用，否则无解释。 | [观察]+[推断] |
| B4 | 二进制首阶段串 `System startup` / `Reg Version: v1.1.0` / `Relocate Boot to DDR` / `Jump to DDR` / `Reg Name:` 与板子页 boot log **逐字一致**；镜像头 @`0x94` 的 `.reg` 文件名 `hi3798mdmo1g_hi3798mv100_ddr3_1gbyte_16bitx2_4layers_emmc.reg` 与板子页 `Reg Name:` 字段**完全相同** → 我们的镜像与该文档板子确属同一 fastboot 家族。 | [观察] |
| B5 | 二进制存在 BootROM→hiboot 的**寄存器握手**（`0xf8a20000` start mode、`0xf80000b0` DOWN 魔数、`0xf8000088` bootstrap type）：说明启动模式由 BootROM 预置、hiboot 读取，与「BootROM 依据引脚选介质」一致。 | [观察]+[推断] |

**支持模型 A（BootROM 从 eMMC p1 取码）的间接证据**

| # | 证据 | 标注 |
|---|---|---|
| A1 | `docs/004 §2.1`：镜像为裸 ARM 映像，由 BootROM 从 eMMC LBA0 加载到 `0x00C00000`；`docs/036 §1.1` 启动链同述。 | 既有文档转述 [存疑] |
| A2 | `docs/006 §5` 场景 C：p1 损坏只能串口 + HiTool 救；`docs/006 §7` 把 p1 放最后一步写。 | 既有文档转述 [存疑] |
| A3 | 板子页 boot log（**不短接**的正常开机）为 `Bootrom start / Boot from eMMC / Initializing DDR ... / Starting fastboot ...` 且 `Boot Media: eMMC`。 | 文档级证据 [观察]（仅证明不短接态） |
| A4 | 4 份镜像内 `fastboot.bin` 字面量 0 命中、`usbboot` 只读分区表 → **被加载镜像内**没有 U 盘 FAT32 bootloader 加载代码。 | [观察]（但代码本应在 BootROM） |
| A5 | 本机无串口、无 HiTool；`docs/001 §7.2` 记「hiboot 如何触发 U 盘 bootargs.bin 尚未从二进制完全确认」。 | [存疑] |

**[推断] 关键消解**：A1/A3 描述的是**不短接**的正常开机（BootROM 从 eMMC 取 p1）；B1 描述的是**短接**态（BootROM 进 USB bootstrap）。二者是**同一引脚的不同电平**，并非互斥（§5.1）。A2 的「p1 损坏只能 HiTool」是把 **Serial bootstrap（HiTool/`libbootrom`，`bootstrap.html` 后半段）** 与 **USB bootstrap（U 盘 `fastboot.bin`）** 混为一谈，且按「无 U 盘 `fastboot.bin`」的最坏情况写成；在短接 + U 盘根有合规 `fastboot.bin` 的条件下不必走到 HiTool。此消解为 [推断]，**仍需本机运行时验证裁决**。

→ **Q3 结论**：**不能从二进制判定**（[未知]）；文档级证据把短接态裁定为 B（[观察]），但本机未做运行时验证（[存疑]）。

---

## 5. Q4 — histb 官方文档原文出处核实

### 5.1 仓库内检索

**[观察]** `TMP/histb-ref/` 仅含 4 份内核/DTS 补丁（`600-17` / `600-18` / `910-02` / `910-03`），`TMP/porting-patches/` 仅含 `500-*` / `600-19` / `600-20` / `910-01` / `910-06` 与 `histb-series.txt`；**均未留存** `bootstrap.html` / `fastboot.html` 的副本或 RST 源。仓库内唯一来源是 `docs/025 §5.5.1/§5.5.2` 的转述与 `docs/025 §6` 的 URL 清单。

### 5.2 公开文档核实（本轮联网取得，均可复现）

**[观察]** 下列 3 页均真实存在，标题与「Edit on GitHub」RST 源如下：

| 页面 | 标题 | 可复现源（页面自带 Edit on GitHub） |
|---|---|---|
| `http://histb-mainline.github.io/software/bootrom/bootstrap.html` | `Bootstrap — histb-mainline documentation`（Sphinx，© Copyright 2024, histb teams） | `https://github.com/histb-mainline/histb-mainline.github.io/blob/master/software/bootrom/bootstrap.rst` |
| `http://histb-mainline.github.io/software/vendor/fastboot.html` | `Fastboot — histb-mainline documentation` | `https://github.com/histb-mainline/histb-mainline.github.io/blob/master/software/vendor/fastboot.rst` |
| `http://histb-mainline.github.io/appendix/boards/ec6108v9c.html` | `EC6108V9C — histb-mainline documentation` | `https://github.com/histb-mainline/histb-mainline.github.io/blob/master/appendix/boards/ec6108v9c.rst` |

**`bootstrap.html` 关键原文（逐字摘录）**：

> ## USB bootstrap
> Short-circuit Pin `USB_BOOT` with GND (pin name may vary). It is Schmitt triggered. Once pulled down, it may affect subsequent boot sequence even if released after bootrom stage. See Fastboot USB Boot.
> This method will also be triggered automatically if no internal storages (eMMC or NAND) are found.
> **Create an FAT32 partition on u-disk, name your bootloader `fastboot.bin` and put it into filesystem root, then plug it into any USB port.**
> Note: You will need other files if you use vendor `fastboot.bin` for USB bootstrap, see Fastboot USB Boot.
> ...
> You can wire the test pin to GND permanently for easy debug. **If no USB storage device is found, bootrom will try to find bootloader from internal storage (eMMC or NAND) instead.**

并附两段启动日志（节选）：

```
Bootrom start / Boot from eMMC / Entry usb bootstrap
Udisk(1):  Initializing DDR ... OK / Starting DDR training ... OK / Starting fastboot ...
```
```
Bootrom start / Boot from eMMC / Entry usb bootstrap
No found fastboot.bin in host:1
No found fastboot.bin in host:2
Initializing DDR ... OK / Starting DDR training ... OK / Starting fastboot ...
<emmc fastboot log follows>
```

**`fastboot.html` 关键原文（逐字摘录）**：

> ## Boot sequence
> 1. If `USB_BOOT` is pulled down, it will try to read two files on u-disk:
>    - `bootargs.bin`: U-Boot env file, sector size: `0x10000`
>    - `recovery.img`: Android bootimg or uImage
>    Otherwise, go to next step.
> 2. Read Android bootimg or uImage from eMMC or NAND storage.

**`ec6108v9c.html` 关键原文**：`USB_BOOT: J16 (near power switch)`（链接指向 `bootstrap.html#usb-boot`）；`bootargs` 段与 `docs/025 §5.5.1` 一致；`Fastboot` 命令全集含 `usbboot - boot from USB device`、`go`、`fatload`、`mmc`、`bootm` 等，与本轮反汇编命令表（50 条）互证；boot log 首阶段串与二进制逐字一致（见 B4）。

**[观察]** `docs/025 §5.5.2` 的转述与上述原文一致（含 `You can wire the test pin to GND permanently for easy debug.` 逐字引用），`docs/025 §6` 的 URL 清单准确。**此前「文档转述，未核实」的缺口已补上。**

**[存疑] 证据等级**：这是 **histb-mainline 社区文档站**（第三方，© 2024 histb teams），**不是**海思官方数据手册，**也不是**本项目设备上的运行时实证。记为**「文档级证据」**；它足以支撑「模型 B 被文档明确描述、且适用于 EC6108V9C 板（J16）」，但不能替代本机零写入真机验证。本机无串口、无 HiTool 的硬约束未变。

---

## 6. A/B 冲突消解、go/no-go 更新、救援物料

### 6.1 A/B 不是互斥模型，而是同一引脚的两个电平

**[推断]** 把 §4/§5 与既有文档拼起来：

```
                     USB_BOOT(J16) 未拉低              USB_BOOT(J16) 拉低（短接）
                     ─────────────────────            ──────────────────────────
BootROM 取码          eMMC LBA0 / p1  → 0x00C00000      USB bootstrap：先找 U 盘 FAT32 根 fastboot.bin
                      (docs/004 §2.1, 板子页 boot log)  找不到 → 回退 eMMC/NAND (bootstrap.html)
被加载镜像            eMMC p1 那份 hiboot               U 盘根那份 fastboot.bin（RAM 执行，不写 flash[推断]）
fastboot 层           USB_BOOT 未拉低 → 从 eMMC/NAND     USB_BOOT 拉低 → 读 U 盘 bootargs.bin + recovery.img
                      读 bootimg/uImage                 (fastboot.html §Boot sequence；二进制 0xc0c698/0xc0c29c/0xc0c344)
                      (正常开机，显示 p5 logo)
```

→ **[推断]** `docs/037 §4.1` 把 A、B 当成同一条件下的互斥假设是**层级混淆**：`docs/036 §1` / `docs/004 §2.1` / `docs/006 §5` 讲的是**不短接**或**无 U 盘 fastboot.bin** 的取码；`docs/025 §5.5.2` 讲的是**短接**态。而「fastboot 读 U 盘 bootargs.bin」是**两个模型共有的 fastboot 层行为**，不构成分歧。**兜底场景（短接 + U 盘）恰好落在模型 B 成立的那一侧。**

### 6.2 go/no-go 更新

**[推断]（基于文档级证据，非运行时实证）**

- `docs/037 §4.3` 的 NO-GO 由 5 条门槛构成。本轮**只推翻其中一条否决项**——§4.1 / §4.2 风险 5 的「写 p1 破坏短接兜底 → 无串口/HiTool 不可逆」：模型 B 由可复现的文档级证据证实，且有 **J16 板级页面 + 社区包根布局 + 二进制首阶段字符串与板子页 boot log 逐字吻合** 三方互证，证据**显著偏向 B**。⇒ **该否决项可被推翻，改 p1 的前置评估可重启**。
- **整体 NO-GO 暂不解除**：门槛 1（显示函数体未定位，[未知]）、门槛 2（`go` 零补丁路径关闭：ABI 不匹配、无可调用 VA）、门槛 3（YZC 私有头 / CRC / 回滚镜像仍 [存疑]）、门槛 4（Live-USB 零写入验证未做）**全部仍成立**，且**仍无显示载荷可打**。「可重启评估」≠「可立即写 p1」。
- **[存疑] 保留项**：① 文档为第三方社区站，本机未做运行时验证；② `docs/006 §5` 场景 C 与文档级证据冲突（§4 A2），未以真机裁决；③ 该板 BootROM 版本/丝印是否与文档板完全一致未核；④ 短接「拉低后即使释放也会影响后续 boot sequence」（`bootstrap.html` 原话）意味着 fastboot 层的 U 盘读取也会被触发，验证时须把这一点计入。
- 因此写真机 p1 的**前置硬条件不变**：先完成 §6.4 的零写入验证，再动 p1。

### 6.3 「U 盘根放哪份 `fastboot.bin`」具体建议

**[推断]** 救援 U 盘（FAT32 / MBR）根目录放置：

| 文件 | 建议 | 理由 |
|---|---|---|
| `fastboot.bin` | **首选**：把 `TMP/community-restore/mv100/fastboot.bin`（539,272 B, `3bded87f…`, 2025-08 构建）复制到根并**改名为 `fastboot.bin`** | 唯一有**本设备实测成功引导**记录的构建：`docs/036 §6.2` / `docs/016` 记社区包 `flashfastboot` 把它写进 p1 且开机成功；YZC 头合法、首阶段代码与顶层逐字节相同。 |
| `fastboot.bin` | **备选 / 可直接沿用**：`TMP/community-restore/fastboot.bin`（539,264 B, `fd5b4ac6…`, 2022-10 构建） | 已在包根、名字与位置合规、YZC 头合法、启动路径代码与首选**结构全等**（§3.1）；文档只要求「一份合法 bootloader 命名为 `fastboot.bin`」。 |
| `fastboot.bin` | 不作首选：`backup_stock/fastboot.img`（`bac0be9f…`, 1 MiB padded 原厂）、`build/verify2/fastboot-burn.bin`（`d5bb8272…`, 本机构建） | 格式同构但**无本机引导验证记录**；原厂那份为 1 MiB padded，未实测 USB bootstrap 接受 padded 镜像。 |
| `bootargs.bin` | 沿用 `TMP/community-restore/bootargs.bin`（65,536 B, CRC `0x1888597E` 校验通过） | 符合 `fastboot.html` 的 `sector size 0x10000`；其 `bootcmd` 首步 `run flashfastboot` 会用 `mv100/fastboot.bin` **重写 p1** → 短接启动即自修复 p1，正是写坏 p1 后的回滚路径。 |
| `mv100/` | 保留（若要用上面的自修复 `bootcmd`） | 提供 `flashfastboot` 的数据源。 |

**零写入验证变体（推荐先做这步）**：把 `bootargs.bin` 的 `bootcmd` 临时改为**不写任何 eMMC** 的可观测命令（如 `version` 或 `printenv`），并把 `mv100/` 移走/改名，使短接启动只验证「BootROM 是否从 U 盘 `fastboot.bin` 取码」；对比启动后显示的版本串（顶层 `81100468` vs 内层 `81082668-dirty`）即可区分 U 盘镜像与 eMMC p1，**此步不写 flash**（`docs/037 §4.4` 步骤 1）。验证通过后再换回完整 `bootcmd`。

### 6.4 写真机 p1 前必须保留的顺序（不因本轮结论放宽）

1. **[观察]** 零写入验证：U 盘根放选定 `fastboot.bin` + 空 `bootcmd` 的 `bootargs.bin` + 短接上电，确认 BootROM 走 USB bootstrap（无串口则用版本串差异等间接可观测结果）。
2. **[观察]** 确认回滚物料齐备：上表 `fastboot.bin` + 完整 `bootcmd` 的 `bootargs.bin` + `mv100/`。
3. **[未知]** 仍须先解决 `docs/037` Q1：定位显示初始化函数体 / 取得可打载荷；在此之前**不进入 p1 补丁设计**。
4. **[推断]** 之后才在 Live-USB 零写入环境验证补丁镜像（`go` / `bootcmd` 级行为），再考虑写真机 p1。

---

## 7. 证据边界、复现与合规

**边界**：本文所有二进制结论来自 4 份 hiboot 的**只读**反汇编 / 结构化扫描，标注了对象 SHA-256、VA / 文件偏移、工具版本（capstone 5.0.7 / radare2 6.2.4 互验）。**未观察到运行时执行**；「0 命中」一律指「在指定对象 / 扫描方式 / 范围内未检索到」，不推出「不存在」。BootROM 掩膜 ROM **不在任何镜像内**，本文**未编造** BootROM 代码或寄存器；§2.3 的 `0xf8a20000` / `0xf80000b0` / `0xf8000088` 是 **hiboot 读取**的寄存器（[观察]），「由 BootROM 预置」为 [推断]。每条结论按 `docs/033 §2` 标 `[观察]` / `[推断]` / `[未知]` / `[存疑]`。

**[未知] 项**：BootROM 实际取码来源在本机的运行时表现、BootROM 私有头（YZC）校验规则、文档板与本机 BootROM 版本一致性、显示初始化函数体 VA。
**[存疑] 项**：模型 B 在本机的真机有效性（仅文档级证据）、`docs/006 §5` 场景 C 与文档级证据的冲突、`0x444f574e` 魔数的确切语义、`fastboot.html` 所称「other files」在 U 盘 fastboot 场景的完整集合、`padded 1 MiB` 原厂镜像能否被 USB bootstrap 接受。

**复现产物（仓库内相对路径，均 gitignored）**：

| 文件 | 用途 |
|---|---|
| `TMP/b038/scan.py` / `scan.log` / `scan-results.json` | 4 份镜像字符串、关键字、字面量/指针 xref、命令表、头部、版本串 |
| `TMP/b038/xdis.py` | 带 bl 目标 / 字面量池 / 字符串解析的 capstone 反汇编 |
| `TMP/b038/xref.py` | 指定 VA 的 `bl` 反向调用者与 `movw/movt` 立即数重建 |
| `TMP/b038/diff.py` / `diff.log` | 顶层 vs 内层逐字节 diff、区域分类、决定性函数结构比对、`fastboot.bin` 字面量统计 |

**合规**：只读静态分析 + 公开文档联网核实；不刷机、不改真机、不构建镜像、**不删除文件**、不用 `rm` / `git clean`、不访问项目目录之外的本地目录、不写入仓库外文件；临时产物全在 `TMP/b038/`；文档不含本机绝对路径 / 用户名 / 卷名，厂商构建机标识省略；**只新建 `docs/038-bootrom-usb-bootstrap-verification.md` 一个文件**，未改动任何已跟踪文件（含 `docs/035`、`docs/037`），未执行 `git add` / commit / push / checkout / 建分支 / 动索引，由主会话统一提交。
