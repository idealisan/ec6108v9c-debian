# 启动路径专项分析：原厂 hiboot 到底走不走 bootcmd

- 分析日期：2026-11-03
- 目的：回答"刷入我们的内核后，原厂 hiboot 会不会按 env 的 bootcmd 启动"
- 前提：**本机从未刷机，以下结论均为静态分析 + 待验证假设，不是实测结论**
- 相关：`005-stock-device-analysis.md`、`004-hiboot-vs-uboot-analysis.md`、`006-restore-to-stock.md`

## 1. 三个互相矛盾的启动地址

| 来源 | 命令 | 目标偏移 | 该处实际内容 |
|---|---|---|---|
| p2 存储环境（CRC 有效） | `mmc read 0 0x1FFBFC0 0x4B000 0x5000; bootm 0x1FFBFC0` | 0x4B000 = **150 MiB** | 随机数据（backup 分区内），**无任何镜像头** |
| hiboot 内置默认 bootcmd | `mmc read 0 0x82000000 0x1D000 0xC000;bootm 0x82000000` | 0x1D000 = **58 MiB** | factory 分区 |
| bootargs 的 blkdevparts | kernel 分区 | **82 MiB** | `ANDROID!` 引导镜像（实测确认） |

三者互不一致，说明**至少有两个不是实际启动路径**。

## 2. 原厂 hiboot 里的 Android 专用代码

在原厂 p1（2016 版 hiboot）中检出的字符串：

```
Enter fun Android_Main
bootcmd
mmc read 0 0x82000000 0x1D000 0xC000;bootm 0x82000000
bootimg 0x1FFBFC0
bootimg recovery/normal
ANDROID!
read misc failed
boot-recovery
find the boot-recovery flag...
enter function sw_ir_detect_recovery
[HMT] read the kernel failed.
[HMT] RSA Verify the kernel Error.
****** boot from second-recovery... ******
***** boot from first-recovery... *****
The recovery verify OK!
```

这说明原厂 hiboot 有一条**完整的 Android 启动链**：
1. `Android_Main` 入口；
2. `bootimg` 命令解析 `ANDROID!` 引导镜像（不是 uImage）；
3. 读 `misc` 判 `boot-recovery` 标志；
4. 红外按键强制进 recovery（`sw_ir_detect_recovery`）；
5. 双 recovery 兜底（first/second-recovery）；
6. RSA 校验钩子（本机 `verify=n` 未启用）。

而我们 **SDK 编译的 hiboot 里没有** `Android_Main`/`bootimg`/`boot-recovery`，
只有 `ANDROID!`（bootm 的通用格式判断），即纯 U-Boot 流程：**执行 env 的 `bootcmd` → `bootm` uImage**。

## 3. 两种可能的启动逻辑

### 假设 H1：先跑 bootcmd，失败再回退 Android_Main
- 存储的 bootcmd 指向 150 MiB（无镜像）→ `bootm` 失败 → 回退到 `Android_Main` → 启动 82 MiB 的 Android boot.img
- 若成立：我们的 env（bootcmd 指向 14 MiB 的有效 uImage）**会被执行并成功**，Debian 能启动
- 也能解释为什么 U 盘刷机脚本能跑（同一套 `run bootcmd` 路径）

### 假设 H2：正常启动固定走 Android_Main，bootcmd 只在 U 盘恢复流程中使用
- 存储的 bootcmd 是历史遗留，正常启动完全不用
- 若成立：刷完我们的包后，原厂 hiboot 仍会去 82 MiB 启动**旧 Android**（我们没覆盖那里）
  → 表现为"刷了没效果"，但**不会变砖**（因为内核/分区写入都是覆盖原 recovery/cache 区域，Android 仍能起）

两种假设下，**U 盘刷机脚本都会被执行**（否则社区方法根本不可能存在），差别只在"刷完之后能不能启动到 Debian"。

## 4. 如何用最小代价判定

### 探针包（零写入，推荐第一步）
release 中的 `mv100-mdmo1g-probe-*.zip`：只有一个 `bootargs.bin`，`bootcmd=reset`。

| 现象 | 含义 |
|---|---|
| 插 U 盘上电后盒子**立即重启/反复重启** | 原厂 hiboot 确实读取并执行了 U 盘 env 的 bootcmd（H1 成立） |
| 插 U 盘仍正常启动 Android | hiboot 未执行该 bootcmd（H2 或触发方式不对） |

拔掉 U 盘再上电即可恢复正常，全程不写 eMMC。

### 分阶段刷机（按风险从低到高）

| 阶段 | 动作 | 成功标志 | 失败后果 |
|---|---|---|---|
| 0 | 跑探针包 | 盒子重启 | 无 |
| 1 | 刷 **stock-hiboot** 包（不写 p1） | 开机进 Debian（说明 H1 成立） | 仍进 Android，无损坏 |
| 2 | 若阶段 1 仍进 Android → 刷 **sdk-hiboot** 包（写 p1） | 开机进 Debian（SDK hiboot 走 bootcmd） | 若 SDK hiboot 有问题：不启动；可用 U 盘还原包写回 p01，或串口 + HiTool |

阶段 2 的关键假设：SDK hiboot 是纯 U-Boot 流程，只要 env 的 bootcmd 正确就会跑 `bootm`。
它保留了对 U 盘 `bootargs.bin` 的支持（已确认字符串），因此即使 p1 被替换，仍可用 U 盘还原包写回原厂 p1。

## 5. 对之前结论的更正

`005` 文档曾写"社区包同款做法，历史验证可行"——**该表述不严谨**：

- "社区包可行"是社区用户的经验描述，不是本机实测；
- 社区包会**同时替换 p1**（mv100/fastboot.bin，2025 构建），其行为可能与 2016 原厂版不同；
- 因此不能把社区经验直接外推到"原厂 p1 + 我们的 env"这一组合。

本机首次刷机应按第 4 节的分阶段流程执行，并以探针结果为准。

## 6. 还原兜底（与 006 文档一致）

- 阶段 1 失败（仍进 Android）：无需还原，直接进入阶段 2 或停止；
- 阶段 2 失败（SDK hiboot 不启动）：插还原 U 盘上电，写回 p01–p15（p1 最后写）；
- 若还原 U 盘也无法触发：串口 + HiTool 烧 `p01_fastboot.img`（BootROM 下载模式）。

## 7. 反汇编验证（2026-11-03 补充）

用 capstone 对原厂 p1（`Fastboot 3.3.0-00786`，载入地址 0xC00000）做全量反汇编（skipdata 模式，
共 258,107 条有效指令），定位到启动主流程：

```
0xC05458  getenv("bootargs_512M")，为空则 setenv 默认值
0xC05474  getenv("bootargs_1G")   ，为空则 setenv "mem=1G mmz=ddr,0,0,380M"
0xC05490  getenv("bootargs_2G")
0xC054AC  printf(版本/环境信息)
0xC054C0  bl 0xC706EC              ; 打印启动横幅（版本串、环境位置等）
0xC054C4  bl 0xC231F4              ; aboot()
0xC054C8  b  0xC054C4              ; 循环
```

### aboot（0xC231F4）的关键逻辑

```
0xC231F8  ldr r1, ="Fastboot 3.3.0-00786..."   ; 打印版本
0xC2320C  ldr r0, ="bootdelay" ; bl getenv
0xC23214  ldr r0, ="bootcmd"   ; bl getenv      ← 取 env 的 bootcmd
0xC2321C  mov sl, r0                            ; sl = bootcmd 字符串
0xC23234  cmp sl, #0
0xC23238  beq 0xC233D0                          ; bootcmd 为空 → 进交互 shell
...
0xC23288  ldr r0, ="Press Ctrl+C to stop autoboot
"
...
0xC233D0  ldr r0, ="fastboot# "                 ; 交互提示符
...
0xC23440  mov r1, r6 ; mov r4, r0 ; mov r0, sl
0xC2344C  bl 0xC222B8                           ; run_command(bootcmd)
0xC23450  mov r0, r4 ; bl 0xC1F84C
0xC23458  b  0xC233D0                           ; 返回后落入 shell
```

**结论（代码级）**：
1. hiboot **确实读取并执行 env 里的 `bootcmd`**（与社区/我们刷机脚本同一条路径）；
2. `bootcmd` 执行失败返回后，进入的是 **`fastboot#` 交互 shell**，**没有**任何"自动回退到 Android_Main"的分支；
3. 因此"原厂 env 的 bootcmd 指向 150 MiB 却仍能启动 Android"**在代码上无法成立** —— 说明实际生效的
   环境不是 p2 里这份（可能被覆盖/来自其他位置），或启动时读取的参数与静态推断不同。

### Android_Main 的归属

| 镜像 | 含 "Android_Main" |
|---|---|
| 原厂 2016 hiboot | **有**（唯一） |
| 社区 2022 / 2025 hiboot | 无 |
| 我们 SDK 构建的 hiboot | 无 |

即 Android 专用启动路径是华为在原厂镜像里加的，社区版与 SDK 版都是纯 U-Boot 流程。
刷入 SDK hiboot 后不存在任何 Android 回退逻辑，完全由 `bootcmd` 决定。

## 8. 对刷机结论的影响（更新）

- 刷机脚本依赖 `bootcmd`，而代码证明 hiboot 会执行它 —— **可行**；
- 但"p2 里的 bootcmd 与实际启动不符"这个矛盾仍未解释，**必须实测**：
  1. 探针包（`bootcmd=reset`）验证 hiboot 是否读取 U 盘 env；
  2. 串口观察 `mmc read` 的实际执行情况（能看到 block# 与结果）；
  3. 若串口显示读 0x4B000 失败后直接进 `fastboot#`，说明该 env 就是真实生效的，只是启动靠其他机制。
## 9. Android 启动路径（静态定位，2026-11-03）

### 9.1 关键发现：镜像用 PIE 方式寻址

代码里大量出现 `add r4, pc, r4` 取基址、再 `add r0, r4, rX` 取字符串，
所以**文件里几乎不存在指向字符串的绝对地址**——这也是最初"只按绝对指针扫不到引用"的原因。

### 9.2 Android 启动链（已定位到指令级）

```
0xC17BF0  bl 0xC70D94            ; android_check(buf, 0x4000000)
            0xC70D94: cmp r1,#0x260 ; ldr r1,="ANDROID!" ; memcmp(buf,"ANDROID!",8)
0xC17C10  bl 0xC70E4C            ; android_image_get_kernel()
0xC17C44  bl 0xC70DC0            ; android_load()（拷贝 kernel/ramdisk 到目标地址）
0xC17C50  getenv("bootargs")
0xC17C88  sprintf("%s initrd=0x%X,0x%X", ...)   ; 把 initrd 参数追加进 bootargs
0xC17CB4  setenv("bootargs", ...)
0xC17CBC  bl 0xC70E88            ; 打印 "Found Initrd at 0x%08X ..."，随后跳入内核入口
```

即：**`bootm <addr>` 在检测到 `ANDROID!` 魔数时走 Android 启动分支**（解析 boot.img 头、
拷贝 kernel+ramdisk、给 bootargs 追加 initrd 参数、跳转）。这就是原厂"能启动 Android"的代码路径。

### 9.3 另外还有一个 `bootimg` 命令

命令表（`cmd_tbl_t`，条目步长 0x1C）中存在：

```
0x93EC4  name="bootimg"  maxargs=16  repeat=1  cmd=0xC2B1A4  usage=0xC8017C
```

`do_bootimg`（0xC2B1A4）是手动解析 boot.img 的工具命令，与 `bootm` 的 Android 分支是两条入口。

### 9.4 结论与仍存疑点

1. **Android 启动路径确实存在，只有 `bootm`/`bootimg` 两种入口**，都要求目标地址上是 `ANDROID!` 镜像；
   不存在"无条件进 Android"的旁路。
2. 因此：只要 env 的 `bootcmd` 指向一个**有效 uImage**（我们的内核在 14 MiB），`bootm` 就走 uImage
   分支启动 Linux —— 这正是刷机包依赖的行为。
3. **仍存疑点**：原厂 p2 的 `bootcmd` 指向 150 MiB，该处无 `ANDROID!` 镜像（实测为随机数据），
   按代码逻辑应失败并落到 `fastboot#`。要解释只能看运行时（串口/再次读设备），静态分析到此为止。
## 10. 动态验证（telnet root，2026-11-03）

ADB 5555 关闭，但 **telnet 23 端口直接给 root shell**（无密码），据此在设备上实测：

| 地址 | 内容 | 判定 |
|---|---|---|
| 58 MiB（内置默认 bootcmd 指向 0x1D000） | 全 0x00 | 无镜像 |
| 82 MiB（blkdevparts 的 kernel 分区） | `ANDROID!` | **真实 boot.img 在这里** |
| 150 MiB（p2 env 的 bootcmd 指向 0x4B000） | 随机数据 | 无镜像 |

补充证据：
- `/proc/uptime` = 7958 s（约 2.2 小时），`btime` 与当前时间差一致 → **设备 2 小时前刚冷启动过**，
  排除了"只是没重启、env 未生效"的可能；
- `/proc/cmdline` 里同时有 `coherent_pool=2M`、`mem=1G mmz=ddr,0,0,400M`，
  而 p2 的 `bootargs` 里并没有这两项 → 说明启动参数**不是**直接取自 p2，更像来自 boot.img 自带 cmdline + 合并默认值。

### 结论

1. 原厂 hiboot 的**正常启动不走 env 的 `bootcmd`**；它走内部 `Android_Main`：
   从 `kernel` 分区（82 MiB）读 boot.img → 校验 `ANDROID!` → 启动。
2. `bootcmd` 只在**升级/覆盖环境**场景下生效（例如 U 盘 bootargs.bin 提供新 env 时），
   这就是社区"U 盘卡刷"能工作的原因。
3. 因此原厂 env 里那条指向 150 MiB 的 `bootcmd` 属于**遗留/无效项**，与正常启动无关。

### 对刷机的直接影响（重要，推翻此前判断）

| 刷机包 | p1 保留原厂 hiboot | 预期结果 |
|---|---|---|
| stock-hiboot 变体 | 是 | **很可能仍启动 Android**（内部 Android_Main 读 82 MiB 的旧 boot.img，而我们的内核写在 14 MiB，不会被读到） |
| sdk-hiboot 变体 | 否（写入 SDK hiboot） | SDK hiboot **不含** Android_Main/bootimg/boot-recovery（字符串计数 0），是纯 U-Boot 流程 → 按 `bootcmd` 启动我们的内核 |

**修正建议：要实现 Debian 启动，必须替换 p1（用 sdk-hiboot 变体）**；
"保留原厂 hiboot 更安全"只在"不打算启动 Debian"的前提下成立。

U 盘刷机流程本身不受影响：升级模式下 hiboot 会读 U 盘 bootargs.bin 并执行其 `bootcmd`，
因此可以先用 U 盘把 SDK hiboot 写进 p1，再由它引导 Linux。
