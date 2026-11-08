# 031 — 原厂 hiboot / fastboot 裸机显示栈反汇编分析（plan B 第 3 步产出）

> 2026-11-08。目标：回答「U 盘刷机过程中能否让 hiboot 在 HDMI 上显示画面」，并尝试提取
> 「出厂可用的显示初始化寄存器序列」，用于校正 `patches/kernel/hi3798mv100-hdmi-console.c`
> 里手搓猜测的寄存器基址 / 偏移。
>
> - 方法：**只读静态反汇编 + 字符串 / 常量 / 交叉引用扫描**（capstone 5.0.7，ARM + Thumb-2）。
>   不刷机、不改真机、不构建镜像、不联网、不删文件、不执行任何 git 操作。
> - 输入二进制全部在项目内；描述本地资源只用仓库内相对路径或通用占位，不含任何本机绝对路径 / 用户名 / 卷名。
> - 前置结论：`docs/027` §4.8 已用 strings 证实 hiboot 含 `PRODUCT_DisplayInit` / `Logo_Main` /
>   `HDMI_Display` / `TX_PHY_*` / `siiSetVideoPath`，并把「反汇编提取精确寄存器写入序列」列为**未做**的下一步
>   （§7.2）；`docs/029` 已厘清 **mv100 走 SiI9134 / MMIO `0x8ce0000`**，`0xf8ce0000` 属 hi3716cv200，
>   本文不再把 `0xf8ce0000` 当 mv100 输出基址（`docs/027` §6 的相关结论按 `docs/029` §6 撤销）。
> - 分析脚本与日志：`TMP/stock-rom-research/hiboot-disasm/`（`scan.py`、`scan.log`，均 gitignored 不入库）。

---

## 0. 四问结论速览

| # | 问题 | 结论 | 置信度 |
|---|---|---|---|
| 1 | `logo` 是可在 `bootcmd` 里调用的 U-Boot 命令吗？ | **不是**。命令表（`cmd_tbl_s`）里没有 `logo` / `logobak`；两者是 **PDM 参数键**，`bootcmd` 里没有可插入的写法。 | 实证（确定） |
| 2 | `PRODUCT_DisplayInit` → `Logo_Main` → `HI_GFX_ShowLogo` 的调用点 / 刷机分支是否做显示初始化？ | **U 盘刷机分支不做显示初始化**：flash 链无显示命令、无视频 console、三份 env 全 `stdout=serial`。这些函数名的**调用点在这批镜像里未能定位**（全量交叉引用为负）；标存疑，不下断言。 | 前半实证 / 后半存疑 |
| 3 | console 设备表里有几个设备？改 `stdout=` 能否让日志到 HDMI？ | **只有 `serial` 一个 stdio 设备**，没有任何视频控制台设备名。改 `stdout=` 不能把 `fatload` / `mmc write` 日志送到 HDMI。 | 实证（确定） |
| 4 | VO/HDMI/PHY 寄存器写入序列（基址+偏移+值+顺序）能列出吗？ | **不能从这批镜像提取**：镜像里没有 `0x8ce0000` / `0xf8ce0000` / `0xf8cc0000` 的 4 字节基址字面量，也定位不到显示函数体。给出可验证的常量清单、与内核驱动的对照，以及替代输入。**不编造寄存器值**。 | 负结果 + 实证边界 |

---

## 1. 输入、链接基址与可复现性

### 1.1 二进制

| 文件 | 大小 | md5 | 说明 |
|---|---|---|---|
| `backup_stock/fastboot.img` | 1,048,576 | `ba131545409ceff565881d85a85c8970` | 原厂 p1 fastboot / hiboot（Fastboot 3.3.0-00786，2016 构建，厂商构建机标识省略） |
| `backup_stock/p01_fastboot_adb.img` | 1,048,576 | `ba131545409ceff565881d85a85c8970` | **与上一行字节完全相同** |
| `backup_stock/p1_fastboot.img.gz` 解压 | 1,048,576 | `ba131545409ceff565881d85a85c8970` | **再次相同**，无新增信息 |
| `TMP/community-restore/fastboot.bin` | 539,264 | `9744881a323629d09d42889c808640a2` | 社区刷机包顶层 hiboot（Fastboot 3.3.0_ecoo，2022），**当前 U 盘刷机的执行者本体** |
| `TMP/community-restore/mv100/fastboot.bin` | 539,272 | `bbead63367a112cdf83b48ecbe17e7fb` | 社区内层另一构建，与上一行有 126,498 字节不同 |
| `build/verify2/fastboot-burn.bin` | 519,468 | `11f7e300b839f61d1ede90cc884f4749` | 本仓库 CI 早期产物，第三份独立构建 |

### 1.2 链接基址 `0x00C00000`（推导，可复现）

三份二进制开头都是经典 ARM 异常向量表：`ea000819`（`b reset`）+ 7 × `e59ff014`（`ldr pc,[pc,#0x14]`），
随后 0x20 起是字面量池（异常处理函数绝对地址），例如原厂镜像为
`0x00C04E80 / 0x00C04F00 / … / 0x00C05180`，社区镜像为
`0x00C04C40 / 0x00C04CC0 / … / 0x00C04F40`。

以「4 字节 word 值 = 某字符串起始偏移 + BASE」做直方图：

- 原厂：`BASE=0x00C00000` 命中 **1706** 个字符串指针，次优 `0x00C01000` 仅 80；
- 社区：`BASE=0x00C00000` 命中 **1310**，次优 `0x00C01000` 仅 74。

→ **运行时地址 = 文件偏移 + `0x00C00000`**，后续所有地址均按此换算。

### 1.3 交叉引用方法（全都做了，结果见 §3 / §5）

1. 绝对指针扫描：任意对齐位置搜索 `struct.pack("<I", BASE+字符串偏移)`；
2. capstone **ARM 全文件**反汇编（`skipdata=True`，覆盖 262,144 / 134,816 条指令），
   收集 `ldr rX,[pc,#imm]` / `adr` 字面量加载，回读指针；
3. capstone **Thumb-2 全文件**反汇编（同样 `skipdata=True`）重复上述；
4. raw ARM `movw`/`movt` 立即数对（759 / 185 对）与 raw Thumb-2 `movw`/`movt`；
5. PIC 相对引用（`add rD,pc,rM` 修正指令 + 小负偏移字面量）；
6. 备用链接基址一致性（要求同一 `(w - 字符串偏移)` 命中多个不同字符串）；
7. ±256 容差指针、低 16 位匹配。

> **重要方法论修正**：capstone 默认 `disasm()` 遇到第一个无法解码的 word 就停止
> （实测只出 16 条指令、止于 `0xC0003C`）。本文所有「全文件」结论均在
> `md.skipdata = True` 下取得；否则「无交叉引用」是假结论。

### 1.4 `cmd_tbl_s` 命令表结构

U-Boot 派生 fastboot 的命令项为 28 字节 `cmd_tbl_s`：

```
+0x00 char *name; +0x04 int maxargs; +0x08 int repeatable;
+0x0c int (*cmd)(...); +0x10 char *usage; +0x14 char *help; +0x18 int (*complete)(...)
```

表位置：原厂 `0x93A2C` 起，社区 `0x801EC` 起，步长 28。校验条件：
`name` 指针落在镜像内且指向短命令名、`1<=maxargs<=64`、`repeatable∈{0,1}`、`cmd` 指针落在代码区。

---

## 2. Q1 — `logo` 是不是 U-Boot 命令？

### 2.1 命令表实证（节选）

原厂镜像 `0x93A9C` 处的典型记录：

```
0x093A9C  name="fatload"  maxargs=6  rep=0  cmd=0x00C18A00
          usage="load binary file from a dos filesystem"
          help="<interface> <dev[:part>]  <addr> <filename> ..."
```

按 §1.4 提取到的命令名（原厂约 45 项 / 社区约 54 项）：

- 原厂：`go` `reset` `bootm` `fatload` `fatls` `fatinfo` `getinfo` `help` `hibernate`
  `clear_bootf` `loadb` `loady` `uploadx` `md` `mm` `nm` `mw` `cp` `cmp` `crc32` `base`
  `loop` `mtest` `unzip` `mii` `mmcinfo` `mmc` `nand` `nboot` `bootp` `tftp` `rarpboot`
  `ping` `saveenv` `printenv` `setenv` `usb` `usbboot` `version` `setproflag` `bootimg` `otp_*`
- 社区：上述大部 + `exit` `run` `true` `false` `showvar` `OTP_getmsid` `OTP_setmsid`
  `OTP_getstbsn` `OTP_setstbsn` `OTP_getvendorid` `otp_settrustzone` `otp_gettrustzonestat`
  `otp_burntosecurechipset` `otpwrite` `otpreadall` `otp_getstbprivdata` `otp_setstbprivdata`
  `otp_getcustomerkey`

**两份表都没有 `logo`，也没有 `logobak`，更没有任何显示 / HDMI / 图形类命令。**
社区表里有 `run`（hush shell，`HUSH_VERSION` 字符串亦在），所以 `bootcmd=run flash*; ...` 能执行。

### 2.2 `logo` / `logobak` 到底是什么

- 原厂镜像里精确字符串 `logo` @`0x81B64`、`logobak` @`0x81B6C`，相邻 8 字节槽位；
  社区镜像 `logo` @`0x6FD84`、`logobak` @`0x70B80`。
- 对 `BASE+偏移` 做**任意对齐**的 4 字节指针搜索：`logo` **0 命中**、`logobak` **0 命中**
  （§1.3 全部 7 种交叉引用方式同样 0 命中）→ 它们不可能是任何 `cmd_tbl_s.name`。
- 紧邻的字符串给出语义（原厂 `0x81B04`–`0x81BFC`）：

```
rcdisp:%d, virscreen:[%d, %d], BGColor:[...]        ← 显示参数输出
logo / logobak                                       ← 两个键名
ERR: HI_Flash_Read!, ReadLen = %#x
there is no logo param!  /  there is no logobak param!
LOGO_TABLE / LOGO_KEY_FLAG / LOGO_KEY_LEN / pqparam
```

配套函数名字符串：`PDM_ReadLogoParam`、`PDM_ReadLogoData`、`HI_DRV_PDM_GetLogoParam`、
`HI_LOGO_DecImg`、`BMP_ADP_CreateDecode`、`HI_GFX_ShowLogo`、
`BOOT_GFX_DisplayLogoWithLayer`、`HI_BOOT_GFX_DisplayWithLayerOrVo`。

→ **`logo` 是 PDM / `LOGO_TABLE` 里的参数键名**，`logobak` 是备份 / fallback 参数键名；
读不到时打印 `there is no logo param!`。`Logo_Main` / `PRODUCT_DisplayInit` 等是**内部函数名**
（函数名字符串表），不是 U-Boot 命令。

### 2.3 `flashlogo` 名字的误导（重要）

三份 `bootargs.bin`（CRC 全部校验通过）里的 `flashlogo` 变量：

```
flashlogo=run loadfilel flashpartitionl
loadfilel=fatload usb 0 0x1000000 mv100/logo.img
flashpartitionl=mmc write 0 0x1000000 0x5000 0x80
```

即 `flashlogo` **只是把 U 盘上的 logo 镜像写进 eMMC logo 分区**，不含任何显示动作。
`bootcmd` 全链（社区包）：

```
run flashfastboot; run flashbootargs; run flashbase; run flashpq; run flashlogo;
run flashkernel; run flashrootfs; run flashbackup; reset
```

全部展开为 `fatload` / `mmc write` / `mmc write.ext4sp` / `crc32` / `reset`。
→ **用户看到的 "Debian Linux" 画面不是刷机进度**，而是 logo 分区内容在（另一次）正常开机路径被画出。

### 2.4 Q1 确定结论

> **`logo` 不是 U-Boot 命令，`bootcmd` 里不存在「插入它重画当前 logo 分区」的写法。**
> 命令表里没有它，字符串也没有任何指针引用；它只是 PDM 参数键。
> 若要在刷机过程中让屏幕重新出图，只有两条工程路径：
> (a) 重启走正常开机显示路径；(b) 修改 hiboot 源码新增一个命令并重新编译刷入 p1
> ——两者都超出「只改 `bootcmd`」的范围，且 (b) 需动 p1，与既有「不动 p1」约束冲突。

---

## 3. Q2 — 显示初始化调用点 / 刷机分支是否做显示初始化

### 3.1 显示相关字符串清单（实证，原厂 / 社区皆有）

| 类别 | 字符串 | 原厂偏移 | 社区偏移 |
|---|---|---|---|
| 函数 / 入口 | `PRODUCT_DisplayInit`, `Logo_Main`, `fastapp_entry` | `0x7937C`, `0x79390`, `0x79430` | `0x6933C`, `0x69360`, — |
| 错误 / 跟踪 | `PRODUCT_DisplayInit err!`, `HI_ADP_DispInit err!`, `boot logo show!!!`, `>>> HDMI_Display in...`, `HI_DRV_PDM_GetLogoData err!` | `0x7F5B4`, `0x7F550`, `0x7F65C`, `0x807F8` | `0x6FCE8`, `0x6FC44`, `0x6FD3C`, `0x72A44` |
| HDMI TX | `HDMI_Display`, `siiSetVideoPath`, `siiGetVideoPath`, `SiI_DeepColor_*`, `ConfigTXVideoMode`, `SW_ResetHDMITX`, `HW_ResetHDMITX`, `TX_PHY_WriteRegister`, `TX_PHY_SwingCtrl`, `TX_PHY_PowerDown`, `TX_PHY_SetDeepColor` | `0x79D18`–`0x79E98` | `0x6C4DC`–`0x6C62C` |
| logo 参数 | `LOGO_TABLE`, `LOGO_KEY_FLAG`, `LOGO_KEY_LEN`, `logo`, `logobak`, `there is no logo param!`, `there is no logobak param!` | `0x81B64`–`0x81BEC` | `0x6FD84`, `0x70B80`, `0x70BA4`–`0x70BDC` |

函数名集中在一段连续 rodata（原厂 `0x79D00`–`0x79F00`），混杂少量数据 word
（如 `0x79D28=0x00002818`、`0x79E04..0x79E18` 一组小值），**未发现与之配对的
(地址, 名字) 符号表**。

### 3.2 全量交叉引用的负结果（可复现，见 §1.3）

对上述全部显示字符串，在 **4 份独立构建**（原厂、社区顶层、社区内层、`fastboot-burn`）中：

- 绝对指针（任意对齐）：**0 命中**；
- ARM 全文件 `ldr [pc]` / `adr` 字面量加载：**0 命中**（对照：`bootcmd`、
  `HUSH_VERSION` 各自有 1 个命中，说明扫描方法有效）；
- Thumb-2 全文件字面量加载：**0 命中**；
- ARM / Thumb-2 `movw`+`movt` 立即数构造：指向 rodata 的 **0 个**；
- PIC 修正指令：`add rD,pc,rM` **0 条**（前 `0x60000` 代码区）；
- 备用链接基址、±256 容差、低 16 位匹配：均无可自洽的多字符串命中。

→ **在这批镜像里定位不到 `PRODUCT_DisplayInit` / `Logo_Main` / `HI_GFX_ShowLogo` 的调用点**，
也找不到任何引用其调试字符串的函数体。字符串是**孤立的 rodata**。
这是「strings 有、代码不可达」的情形，必须标 **存疑**：
可能是该 SDK 显示库在这些构建里被裁剪 / 死代码保留字符串、显示代码在运行时另行加载的另一模块，
或字符串表按索引取用而非常规指针引用。本文**不据此断言「硬件上不存在显示初始化」**。

### 3.3 `bootcmd` 执行路径（实证）

社区镜像 `bootcmd` 字符串 @`0x7B6C3`，其字面量引用在 `0x16E50`，加载点在 `0xC16C54`。
反汇编该处所在函数（起始 `0xC16C14`，即 `main_loop` 一类）：

```asm
00c16c14  push {r4,r5,r6,r7,sb,sl,fp,lr}
00c16c18  sub  sp, sp, #0x58
00c16c1c  ldr  r1, [pc, #0x220]
00c16c20  ldr  r0, [pc, #0x220]
00c16c24  bl   0xc10920
00c16c28  bl   0xc162b8
00c16c2c  bl   0xc12500
00c16c30  ldr  r0, [pc, #0x214]
00c16c34  bl   0xc10998          ; getenv(...)
00c16c38  cmp  r0, #0
...
00c16c54  ldr  r0, [pc, #0x1f4]  ; <- "bootcmd" 字符串指针
00c16c58  bl   0xc10998          ; getenv("bootcmd")
00c16c78  bl   0xc61440          ; run_command 链
```

原厂镜像同构（`bootcmd` 字面量 @`0x23468`，周边 `0xC233D0`–`0xC23458`）。

三份 `bootargs.bin` 的 console 与链（CRC 全 OK）：

| 文件 | `stdout/stdin/stderr` | `bootdelay` | `bootcmd` 首段 |
|---|---|---|---|
| 官方包 `release-ex/bootargs.bin` | `serial` ×3 | `0` | `run flashkernel; run flashrootfs; run flashbootargs; run flashlogo; reset` |
| 社区顶层 `bootargs.bin` | `serial` ×3 | `0` | `run flashfastboot; ...; run flashbackup; reset` |
| 社区内层 `mv100/bootargs.bin` | `serial` ×3 | `0` | `mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0` |

链中所有命令均为 `fatload` / `mmc read|write|write.ext4sp` / `crc32` / `reset` / `run`，
**没有显示命令**（§2.1 命令表亦无）。

### 3.4 Q2 结论（分两层，严格区分）

> **实证（确定）**：U 盘刷机执行的 `bootcmd` 链**不做显示初始化、也不刷新 HDMI**。
> 依据：命令表无显示命令；三份 env 的链全是分区搬运 + `reset`；console 只有 serial（§4）；
> 刷机执行者镜像内找不到可定位的显示初始化调用（§3.2）。
> 这与用户「刷机时显示器背光都不亮」的观察一致：
> **背光不亮对应的就是这条 U 盘 `fastboot.bin` + `bootargs.bin` 路径**。
>
> **存疑（不下断言）**：`PRODUCT_DisplayInit → Logo_Main → HI_GFX_ShowLogo` 究竟挂在
> `board_init_r` / `main_loop` 之前、`bootm` 分支、还是仅正常 eMMC 开机才走，
> **这批镜像无法给出调用点**（§3.2 负结果）。因此不能声称「原厂正常开机一定由 p1 hiboot 点亮」，
> 只能说：刷机链本身没有任何可用的显示入口，`Debian Linux` 画面来自 logo 分区在别的时机被画出。

与 `docs/027` §7.2 的关系：该节把「反汇编提取精确寄存器写入序列」列为未做；
本步**实际执行了反汇编**（§1.3 / §5），结论是**负结果**，并把边界如实记录。

---

## 4. Q3 — console 设备表 / `stdout=` 能否输出到 HDMI

### 4.1 设备名字符串扫描（4 份构建一致）

| 字符串 | 原厂 | 社区 | 说明 |
|---|---|---|---|
| `serial` | 1 处（`0x8AEC6`） | 1 处（`0x7A9F4`） | 唯一的 stdio 设备名 |
| `stdin` / `stdout` / `stderr` | 各 1 | 各 1 | env 变量名 |
| `vidconsole` | 0 | 0 | 无视频控制台 |
| `vesa` | 0 | 0 | 无 |
| `cfb_console` | 0 | 0 | 无 |
| `lcd` | 0 | 0 | 无 |
| `nulldev` / `usbtty` | 0 | 0 | 无 |

### 4.2 `serial` 注册函数反汇编（实证）

社区 `0xC18444` 起（原厂同构 @`0xC253C0`）：

```asm
00c18444  mov  r2, #0x10
00c18448  ldr  r1, [pc, #0x48]     ; <- "serial" 字符串
00c1844c  add  r0, sp, #0xc        ; device_t 结构栈上构造
00c18450  bl   0xc5c58c            ; memcpy(name, "serial", 16)
00c18454  mov  r3, #0x80000003     ; flags
00c18458  str  r3, [sp, #4]
00c18460  ldr  r3, [pc, #0x34]     ; 函数指针 putc/puts/tstc/getc...
00c18468  str  r3, [sp, #0x24]
...（共 4 个函数指针字面量）
00c18484  bl   0xc183dc            ; device_register / stdio_register
```

`serial` 字符串只有 **2 个**指针引用：其一在 USB 命令的字符串表里，其二就是这个
`device_t` 注册路径。全镜像**没有第二个 stdin/stdout 设备注册点**。

### 4.3 Q3 确定结论

> **console 设备表里只有 `serial` 一个 stdio 设备**（外加 env 的 `stdin/stdout/stderr` 三个指向它的槽位）。
> 不存在 `vidconsole` / `vesa` / `cfb_console` / `lcd` 等任何视频控制台设备。
> 因此 **改 `stdout=` 不能让 `fatload` / `mmc write` / `crc32` 的日志出现在 HDMI**：
> 指定一个未注册的设备名，U-Boot 只会报错 / 回退，不会把串口输出重定向到帧缓冲。
> 而本机没有引出串口硬件 —— 刷机过程既无 HDMI 输出、也无法读到串口日志，
> 这正是当前调试只能依赖 pstore / 绿带标记的原因。

---

## 5. Q4 — VO/HDMI/PHY 寄存器写入序列（诚实边界）

### 5.1 二进制常量实证

对 4 份 hiboot 镜像做 4 字节小端基址字面量搜索（`0000ce08` / `0000cef8` / `0000cc08` /
`0000ccf8` / `000000f9` / `0018ce08` / `0018cef8`）：

| 基址 | 原厂 hiboot | 社区 hiboot | 含义 |
|---|---|---|---|
| `0x8ce0000`（mv100 HDMI，见 `docs/029`） | 0 | 0 | 无字面量 |
| `0xf8ce0000`（hi3716cv200 HDMI，见 `docs/029`） | 0 | 0 | 无字面量 |
| `0x8cc0000` / `0xf8cc0000`（VO/VDP） | 0 | 0 | 无字面量 |
| `0xf9000000` / `0xf8ce1800` | 0 | 0 | 无字面量 |

raw ARM `movw`/`movt` 立即数对里出现的 MMIO 区间常量（原厂 759 对中）：
`0xf8ab0000` ×12、`0xf8c40000` ×6、`0xf8001000` ×5、
`0x80100005/6/7/0b/0d`、`0xb0008000/…`、`0xa0648001/…` 等。
这些**不是**已确认的 HDMI TX / VO 基址，不能拿来当寄存器序列用（避免误判，本文不下结论）。

交叉参考 `docs/027` 已抽取的 **Android 内核 vmlinux 与 p15_system**：

| 常量 | p11 vmlinux | p15_system（Android 用户态） | 判定 |
|---|---|---|---|
| `0xf8cc0000`（VO/VDP） | 14 处 | ≥12 处 | SDK `CONFIG_VDP_REG_BASEADDR`，多處实证 |
| `0xf9000000`（VO/VDP 备用区） | 21 处 | ≥12 处 | fbprobe 定义区 |
| `0xf8ce0000` | **0** | ≥12 处 | 仅见于 Android 用户态库；按 `docs/029` §3 属 hi3716cv200 / SDK 条件编译常量 |
| `0x8ce0000`（mv100 DT reg） | **0** | 0 | 该批 Android 二进制里没有此形式 |

### 5.2 与 `patches/kernel/hi3798mv100-hdmi-console.c` 的对照

| 驱动现有值 | 来源 | 本镜像 / `docs/029` 校验 | 判定 |
|---|---|---|---|
| `VO_REG_BASE 0xf8cc0000` | SDK `drv_hifb_config.h`（`docs/023` §4.2） | vmlinux + p15_system 均有该常量；hiboot 镜像内无字面量 | **基址有旁证**，非纯猜测；但 hiboot 层未验证 |
| `VO_G0_ADDR +0x494`、`G0_STRIDE +0x49c`、`G0_IRESO +0x4a0` | SDK `S_VDP_REGS_TYPE` 偏移推导 | 本次 hiboot 反汇编**未验证**（无显示函数体） | 沿用 SDK 推导，标待核 |
| `HDMI_TX_BASE 0xf8ce0000`（仅 fallback 扫描） | SDK `drv_reg_proc.h` | `docs/029` 明确该地址属 **hi3716cv200**；mv100 DT 为 `0x8ce0000` | **需校正**；用 cv200 地址扫 mv100 寄存器是错的 |
| 读 hiboot 留下的 VO layer0 寄存器做 simplefb 交接 | 设计假设 | 刷机分支未做显示初始化（§3.4）；若该路径不写 VO layer0，则读到的可能是 0 / 随机值 | **假设在刷机路径不成立**，与黑屏症状一致 |

### 5.3 为什么给不出「基址+偏移+值+顺序」表

`docs/022` §4 里 `HDMI_Display()` 的初始化序列（**来自 HiSTB SDK 源码，不是本次反汇编实证**）为：

```
HI_UNF_HDMI_GetSinkCapability() 读 EDID → 按 enHdFmt 设 colorimetry/aspect
→ UpdateTX_656() → SetIClk(0) → WakeUpHDMITX()
→ siiSetVideoPath() / SetIClk() / AVI InfoFrame + VIC
→ TX_PHY_HighBandwidth() / TX_PHY_SwingCtrl()
→ TX_SetHDMIMode() → TX_PHY_EnableHdmiOutput()
```

hiboot 镜像里**只有这些函数名字符串**（`0x79D18`–`0x79E98` / 社区 `0x6C4DC`–`0x6C62C`），
**没有可定位的函数体、没有 HDMI/VO 基址字面量、没有引用其调试串的代码**（§3.2 / §5.1）。
因此：

> **无法从这批镜像反汇编出可验证的寄存器写入表。本文不编造任何寄存器值、偏移或顺序。**
> 「出厂可用的显示初始化寄存器序列」的权威输入目前仍是 **HiSTB SDK 源码**
> （`docs/021` §3 / `docs/022` §4 / `docs/023` §4.2：`hdmi_1_4/hdmi.c`、`drv_pdm.c`、
> `si_vmode.c` / `vmtables.c`、`hi_reg_vdp.h`），或需要一份**确实包含并调用显示代码**的
> hiboot / graphic 模块二进制再做反汇编。

### 5.4 一个有价值的旁证：SiI9134 方向

hiboot 函数名表里出现 `siiSetVideoPath` / `siiGetVideoPath` / `SiI_DeepColor_{24,30,36}bit` /
`ConfigTXVideoMode` / `TX_SetHDMIMode` / `TX_PHY_*` —— 这是 **SiI 系列 HDMI 发送器 SDK 的
函数命名**，与 `docs/029` 「mv100 通过 SoC 内 MMIO 窗口访问 SiI9134 IP」的结论**方向一致**；
`docs/027` §6 依据 `0xf8ce0000` 常量认「片内 HDMI TX、推翻外挂 sii9134」的结论按
`docs/029` §6 撤销。该旁证也说明：plan B 应按 **bridge 链路**
（`500-01` + `500-02` sii9134/`hi3798mv100-hdmi.c` + `600-18` video path up）取补丁，
而不是 `600-17` 的 mv200 片内 `histb-hdmi.c`。

---

## 6. 对两个用户现象的回答

1. **"Debian Linux" 画面**：是 `LOGO_TABLE` / logo 分区（`p5`/`p7`，社区包写 `mv100/logo.img`
   到 `0x5000` 扇区）内容被画出，**不是刷机进度条**。`flashlogo` 只是 `fatload` + `mmc write`，
   不触发显示；命令表里也没有任何显示命令（§2）。
2. **「刷机时显示器背光都不亮」**：对应 **U 盘 `fastboot.bin` + 顶层 `bootargs.bin` 路径**。
   该路径：`bootdelay=0` 直接跑 `bootcmd`；链里只有分区搬运 + `reset`；console 只有 `serial`
   且本机无串口；执行者镜像里找不到可定位的显示初始化调用（§3）。
   → **刷机过程既不刷新 HDMI，也没有任何可用的显示输出入口**。

---

## 7. 下一步建议（plan B 第 3 步之后）

1. **换正确的二进制再反汇编**：本批 4 份 hiboot 都只有显示字符串、没有可达显示代码。
   需要找到含 `PRODUCT_DisplayInit` 函数体的镜像（完整 SDK hiboot 构建 / graphic 模块），
   或直接反汇编 `docs/027` 已抽取的 **p11 vmlinux（17.4 MB）** 里的
   `HI_DRV_HDMI_*` / `DRV_HDMI_*` / `HDMI_TX_PHY_BASE_ADDR` 相关函数，提取真实寄存器写入。
2. **与 SDK `HDMI_Display()` 逐字节核对**：把提序列与 `TMP/sdk-src/` 的
   `hdmi_1_4/hdmi.c`、`drv_pdm.c`、`si_vmode.c` 对照（pmOS / odin 经验：
   初始化序列要逐字节来自原厂资产，不要手写猜，`docs/025` §2.2）。
3. **发送器形态已厘清，直接定基线**：按 `docs/029`，mv100 = SiI9134 / `0x8ce0000`，
   取 bridge 链路补丁（§5.4）；不再沿用 `docs/025` §8「外挂 sii9134 措辞」或
   `docs/027` §6 的片内 TX 说法。
4. **校正内核驱动**：`hi3798mv100-hdmi-console.c` 的 `HDMI_TX_BASE=0xf8ce0000`
   是 cv200 地址，应改为 mv100 的 `0x8ce0000`（或按板级 DT `reg` 复核）；
   `VO_REG_BASE=0xf8cc0000` 有 vmlinux / Android 库旁证但需按 mv100 映射再确认；
   G0 偏移仍以 SDK `hi_reg_vdp.h` 为准。
5. **若要求刷机期可见**：只能改 hiboot（新增显示命令 / 在 `bootcmd` 前恢复显示），
   属改 p1 的工程决策，与「不动 p1」既有约束冲突；更现实的是保留 pstore + 绿带标记作为反馈通道。
6. 全过程继续遵守：CI 出包、不本地构建镜像、不刷机改真机、不删文件、隐私红线。

---

## 8. 复现与隐私

- 脚本：`TMP/stock-rom-research/hiboot-disasm/scan.py`（本步主扫描）；
  `TMP/stock-rom-research/` 下 `rtools.py` / `step1~4.py` / `RESEARCH-NOTES.md`（`docs/027` 的素材）。
- 日志：`TMP/stock-rom-research/hiboot-disasm/scan.log`。
- 工具：Python 3 + capstone 5.0.7（ARM / Thumb-2，`skipdata=True`）；未使用任何联网 / 刷机 / 构建工具。
- 二进制来源已在 §1.1 用**仓库内相对路径**列出；原厂镜像内携带的厂商构建机标识 / 绝对路径字符串
  在本文中一律省略，未写入任何文件。
- 本文只新建 `docs/031-hiboot-baremetal-display.md` 一个文件，未改动任何已跟踪文件，
  未执行 `git add` / commit / push / checkout / 建分支 / 动索引，由主会话统一提交。
