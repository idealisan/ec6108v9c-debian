# 不动 p1 的两种方案：Live-USB 调试 + 写入 eMMC（boot.img 包装）

- 分支：`main`
- 日期：2026-11-03
- 硬约束（用户）：
  1. **eMMC 的 p1（hiboot）绝对不写** —— 没有串口线，改坏了无法恢复；
  2. 只能通过**短接触点**进入 USB 升级模式；
  3. 任何刷写都必须能在"无串口"的前提下回滚。

## 1. 由约束推出的结论

原厂 hiboot 的**正常启动固定走内部 Android_Main**（详见 `007` 第 10 节），
读 `kernel` 分区（p11，82 MiB）的 boot.img 启动；env 的 `bootcmd` 只在升级模式生效。

所以：
- 不能靠"改 env + 保留原厂 hiboot"来启动 Linux（正常启动不看 env）；
- 也不能换 hiboot（违反约束 1）。

**唯一可行的落点是：把 Linux 内核包装成 Android boot.img，写进 p11**，
让原厂 hiboot 用它的 Android 启动路径把我们的内核拉起来。

## 2. 方案 A：Live-USB（零写入，调试用）

- U 盘：FAT32 单分区，放 `bootargs.bin` + `live/uImage`
- `bootargs.bin` 内容：`bootcmd=fatload usb 0 0x08000000 live/uImage; bootm 0x08000000`
- 用法：**短接上电** → hiboot 进入升级模式 → 读 U 盘 env → 从 U 盘启动内核
- 根文件系统：U 盘第二个分区（ext4），内核 cmdline `root=/dev/sda2 rootwait rw`
- **完全不写 eMMC**；拔盘重启即回 Android
- 缺点：每次启动都要短接一次（这是原厂 hiboot 的机制，无法绕过）
- 前提：内核必须把 `usb-storage` 编成内置（现在是模块，要改成 `=y`）

## 3. 方案 B：写入 eMMC（长期使用，同样不动 p1）

### 3.1 分区映射（全部复用原厂布局）

| 原厂分区 | 原内容 | 改造后 | 可回滚 |
|---|---|---|---|
| p1 fastboot | hiboot | **不动** | — |
| p2 bootargs | 原厂 env | 改 `root=/dev/mmcblk0p16` | 备份 p02 可写回 |
| p11 kernel | Android boot.img | **换成包着 Linux 内核的 boot.img** | 备份 p11 可写回 |
| p16 userdata | Android 数据 | **Debian rootfs（ext4）** | 备份 p16 可写回 |
| 其余 | — | 不动 | — |

### 3.2 为什么要用 Android boot.img 格式

原厂 hiboot 的 Android 分支做这些事（`007` 第 9 节）：

```
memcmp(buf, "ANDROID!", 8)        ; 校验魔数
读取 kernel_size / kernel_addr / ramdisk_size
把内核拷到 kernel_addr，跳转执行
在 bootargs 后追加 initrd=...（有 ramdisk 时）
```

所以只要做一个合法的 boot.img：

| 字段 | 取值 |
|---|---|
| kernel | 我们的 `zImage-dtb`（zImage + 尾附 DTB），**不带 uImage 头** |
| kernel_addr | `0x02000000` |
| ramdisk | 空（ramdisk_size=0，代码支持） |
| cmdline | `console=ttyAMA0,115200 root=/dev/mmcblk0p16 rootwait rw blkdevparts=...` |

原厂 hiboot 会把它当 Android 内核启动，实际跑的是 Linux。

### 3.3 刷写与回滚（都不需要串口）

刷写（短接进入升级模式）：

```
p11 <- boot.img（Linux）
p16 <- Debian rootfs（ext4，6 GB 分区，sparse 写入）
p2  <- 新 bootargs（root=/dev/mmcblk0p16，保留原厂 blkdevparts）
```

回滚（同样短接 + U 盘）：

```
p02/p11/p16 <- 备份镜像（stock-restore 包扩展这三项）
```

因为 p1 从未变动，**任何失败场景都还能通过短接 + U 盘把 p2/p11/p16 写回**，
不需要串口、不需要 HiTool。

### 3.4 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| boot.img 不被接受 | 缺 ramdisk 或 addr 不对 | 先用方案 A 验证内核能跑，再做 B；boot.img 参数按原厂 p11 头解析结果对齐 |
| 写 p11 失败 | 启动不了 | 短接 + U 盘写回 p11 备份 |
| 写 p16 失败 | 根文件系统坏 | 重新刷 p16 |
| 短接不稳定 | 进不了升级模式 | 多试几次；这是唯一入口，需确认短接点 |

## 4. 与原计划的差异

| 原计划 | 现计划 |
|---|---|
| 刷 sdk-hiboot 到 p1 | **永不刷 p1** |
| 内核写 14 MiB（社区布局） | 内核包装成 boot.img 写 **p11（82 MiB）** |
| rootfs 写 p9（610 MiB 起） | rootfs 写 **p16（userdata，1302 MiB 起，6 GB）** |
| 需要改 bootargs 的 blkdevparts | **保留原厂 blkdevparts**，只改 root= |

好处：分区布局不变，回滚只涉及三个分区，且全都能用 U 盘恢复。

## 5. 执行顺序

1. **探针**（零写入）：确认短接 + U 盘 env 的链路可用 —— 已完成打包，等实测
2. **方案 A**：改内核（`usb-storage=y`）→ 出 Live-USB 包 → 短接启动，验证 Linux 能跑、能上网、能 SSH
3. **方案 B**：用验证过的内核生成 boot.img → 出 eMMC 刷机包（只写 p2/p11/p16）→ 刷入
4. 任意阶段失败：短接 + U 盘回滚

## 6. 待确认

- [ ] 探针实测结果（短接是否稳定、hiboot 是否执行 U 盘 env）
- [ ] 原厂 p11 的 boot.img 头参数（kernel_addr/ramdisk_addr/tags_addr/page_size）——
      需要从 `p11_kernel.img` 备份里读出，作为我们 boot.img 的模板
- [ ] 内核 `usb-storage` 改内置后，Live-USB 能否挂上 ext4 根分区
