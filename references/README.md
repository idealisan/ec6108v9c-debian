# 参考资料存档说明

本目录存放与 EC6108V9C 刷机相关的**第三方资料与工具**，目的是避免原始链接失效（死链）后无法复现。
CI 会把本目录内容与下列仓库的**固定 commit 快照**一起打包，作为 release 资产发布。

## tools/

| 文件 | 说明 |
|---|---|
| `USBFormat.exe` | 社区教程要求使用的 U 盘格式化工具（NSIS 2.46 打包，内含 fbinst.exe，作者 teasiu@163.com）。分析见 `docs/003-usb-format-tool-analysis.md`。sha256 记录在 `SHA256SUMS` 中。 |

Windows 未签名程序，运行需管理员权限并直接写物理磁盘，建议仅在虚拟机/旧机器使用；等效做法见 003 文档第 5 节。

## snapshots/（由 CI 生成，不在仓库内）

| 资产名 | 来源 | 说明 |
|---|---|---|
| `snapshot-glinuz-hi3798mv100-<sha>.tar.gz` | https://github.com/glinuz/hi3798mv100 | 中文编译/烧录教程 + HiTool 截图 + `emmc_partitions.xml` + 内置 SDK SPC041B020 |
| `snapshot-histb-sdk-SPC050-<sha>.tar.gz` | https://github.com/JasonFreeLab/HiSTBLinuxV100R005C00SPC050 | 海思 HiSTB Linux SDK（含 hiboot/fastboot 源码） |
| `snapshot-histb-SPC060-fastboot-<sha>.tar.gz` | https://github.com/zjkanjie/HiSTBLinuxV100R005C00SPC060 | 仅抽取 `source/boot/fastboot`（hiboot 源码，U-Boot 3.3.0 分支） |

每次构建都会在 `dist/references-<stamp>.tar.gz` 里写入 `MANIFEST.txt`，记录来源 URL、commit、抓取时间、sha256 与大小。

## 版本关系

- SPC041B020 ⊂ glinuz 仓库；SPC050（JasonFreeLab）与 SPC060（zjkanjie）为不同版本的同代 SDK
- 我们镜像里的 hiboot 是 "Fastboot 3.3.0_ecoo_81082668"，对应 SDK 的 `source/boot/fastboot`（见 `docs/004-hiboot-vs-uboot-analysis.md`）
- 内核移植与 rootfs 方案见 `docs/002-mainline-kernel-debian-survey.md`
