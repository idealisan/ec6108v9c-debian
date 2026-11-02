# USBFormat.exe（U 盘格式化工具）分析

- 分析日期：2026-11-02
- 分析对象：社区刷机教程要求使用的 `USBFormat.exe`
- 分析方法：静态解包（NSIS 安装包 LZMA 解压 + fbinst 二进制字符串与 PE 头分析），未在本机执行
- 相关文档：`docs/report.md`（引导与刷机机制）、`docs/mainline-kernel-debian-survey.md`（内核/rootfs 路线）

## 1. 结论

`USBFormat.exe` 本身不是格式化程序，而是一个 **NSIS 2.46 自解压安装包**（未签名，清单申请 highestAvailable 即管理员权限），
作者 **teasiu@163.com**（海纳思系统作者，界面署名"神雕teasiu作品"）。

包里真正干活的是 **`fbinst.exe`（2011-01-25 编译，fbinst 1.6 系）**，界面实际调用的命令为：

    "cmd" /c "echo y| <tmp>\\fbinst <U盘> format --raw --force --align --fat32"

即：用 fbinst 以"正常布局（非启动盘）+ 强制重建 + 簇对齐 + FAT32"参数把整块 U 盘重新格式化。

> 该结论来自 NSIS 脚本字符串（LZMA 解压 NSIS 头后提取），非猜测。

## 2. 包内结构

NSIS 安装包解出 7 个文件：

| 文件 | 大小 | 说明 |
|---|---|---|
| `$PLUGINSDIR/fbinst.exe` | 76 KB | 真正的格式化工具（PE32 console，2011-01-25） |
| `$PLUGINSDIR/nsExec.dll` | 6.6 KB | NSIS 插件，静默执行 fbinst 并回显日志 |
| `$PLUGINSDIR/nsDialogs.dll` | 9.7 KB | NSIS 插件，U 盘选择对话框 |
| `$PLUGINSDIR/System.dll` | 5.9 KB | NSIS 插件（枚举驱动器） |
| `$PLUGINSDIR/ButtonLinker.dll` | 7 KB | 界面按钮/链接 |
| `$PLUGINSDIR/modern-header.bmp` / `ad.bmp` | 29 / 75 KB | 仅界面图片 |

无其他功能模块，不写隐藏分区、不装驱动、不联网。

## 3. fbinst 参数逐条解读

| 参数 | 官方帮助文本 | 实际作用 | 对刷机的意义 |
|---|---|---|---|
| `--raw` | Format with normal layout (not bootable) | 普通 MBR 布局，**不创建 UD 隐藏区、不写引导代码** | 生成普通 MBR 盘（界面写"可启动"仅为宣传） |
| `--force` | Force the creation of data partition | 强制重建分区、全盘覆写 | 清除旧分区表/残留，回收全部容量 |
| `--align` | Align to cluster boundary | 数据区起始按簇边界对齐 | 老 FAT 驱动解析更稳 |
| `--fat32` | Format data partition as FAT32 | FAT32（簇大小自动） | 绕过 Windows 自带工具 >32GB 不能选 FAT32 的限制 |

界面文案（GBK 提取）佐证：

- 【U盘格式化小工具】
- "63扇区保留,可启动U盘格式化.适用于20G以下USB磁盘"
- "本工具将使您的U盘格式化为63扇区HDD模式."
- "FAT32格式化此U盘"
- "格式化U盘可以取回全部空间，继续吗？"

即布局为：**MBR + 单个主分区、分区起始约 LBA 63（再按簇对齐取整）+ FAT32 + 全部容量**。

## 4. 为什么社区要求必须用它

结合 `docs/report.md` 中逆向的 hiboot（`fastboot.bin`）行为，其 `fatload usb 0` 是一个极简 FAT 驱动，只认：

1. **MBR** 分区表（不认 GPT）
2. **第一个主分区**（不认逻辑分区/多分区）
3. **FAT32**（不认 exFAT / NTFS / FAT16）
4. 分区起始为老式低偏移（63 / 2048 这类）

而当前 Windows/macOS 默认格式化 U 盘常用 exFAT、GPT 或 superfloppy（无 MBR）布局，
hiboot 会直接看不到文件，表现为"插上 U 盘刷机无反应"。
该工具的作用就是一次性规避这些差异，**不包含任何隐藏操作或私有协议**。

## 5. 等效替代做法

无需使用该工具，只要复刻同样布局即可。

macOS：

    diskutil list
    diskutil eraseDisk MS-DOS BOOT MBR /dev/rdiskN

注意必须指定 MBR 方案，不要用 GPT。

Linux：

    sudo parted /dev/sdX mklabel msdos
    sudo parted -s /dev/sdX mkpart primary fat32 63s 100%
    sudo mkfs.vfat -F 32 -s 8 /dev/sdX1

`-s 8` 表示 4 KB 簇，对老 FAT 驱动更保守。

Windows（不想用第三方工具时）：

    diskpart
    list disk
    select disk N
    clean
    create partition primary
    format fs=fat32 quick
    active
    assign

## 6. U 盘合规自检

- `fdisk -l` / `diskutil list` 中只有一个主分区，类型 0x0b / 0x0c
- 分区起始扇区 <= 2048（63 最稳）
- 文件系统为 FAT32，簇大小 <= 32 KB
- 不存在 GPT 头（`gdisk -l` 不应显示 GPT）
- 拷贝文件后 hiboot 能 fatload 到（可用串口观察）

## 7. 风险提示

- 该 exe 为 **2011 年的未签名二进制**，运行需管理员权限并直接写物理磁盘；
  建议在虚拟机或专用旧机器上执行，或直接使用第 5 节的等效命令
- 工具界面标注"适用于 20G 以下 USB 磁盘"；大容量盘建议 8-32 GB
- 格式化会**完全覆写** U 盘数据且不可恢复，操作前务必备份
