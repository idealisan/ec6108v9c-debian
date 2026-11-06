# 追加调查：Android 5.x BSP 是否存在

- 分支：`android7`
- 日期：2026-11-03
- 背景：用户接受 5.x（Lollipop）作为替代方案

## 1. 结论

**存在，而且有两条独立线索。**

| 线索 | 内容 | 可用性 |
|---|---|---|
| 官方 BSP | **HiSTBAndroidV600R001C00SPC0xx**，兼容列表明确覆盖 **Hi3798MV100 BGA/QFP**，文档日期 2016-05-30 | 文档公开（含开发指南/FAQ/兼容列表）；**源码 tar.gz 未见公开** |
| 社区固件 | ZNDS 2025-12 的「MG100/MG101/UNT400B/M101 通刷包」，标注 **Hi3798MV100 + Android 5.1.1**，支持 RTL8188/RTL8723/MT7601 无线 | 可下载（需论坛回复取链），非 Android TV |

## 2. 官方 BSP 证据

- 仓库 `wudilsr/HiSTBAndroidV600R001C00SPC064`（466 MB，**仅文档**）：
  - `hardware/HiSTBAndroidV600R001C00SPC064 Compatibility List.xlsx` → 列出 Hi3798MV100 BGA / Hi3798MV100 QFP / Hi3796MV100
  - `hardware/Hi3798MV100/`、`hardware/Hi3796MV100/` 目录存在
  - `release notes/…版本描述文件.doc`：版本序列 SPC030 → SPC064，发布包名 `HiSTBAndroidV600R001C00SPC064.tar.gz`（源码在发布包 Software 目录）
- 源码目录只有骨架：`qinxiongxu/HiSTBAndroid`（27 MB，分支标注 SPC064）
  - 含 `device/hisilicon/{Hi3798MV100, Hi3796MV100, bigfish}`
  - `BoardConfig.mk` 指向 `hi3796mv100_android_defconfig`、平台 `bigfish`
- 编译方式（社区博客）：`lunch Hi3798MV100-eng; make bigfish`
- 该 SDK 对应的内核仍是 **Linux 3.10.0_s40**（与现机一致）

**修正（2026-11-03 复核）**：V600R001 **就是 4.4.2 线**，不是 5.1。

证据：`qinxiongxu/HiSTBAndroid`（V600R001C00SPC064 源码骨架）的
`device/hisilicon/Hi3798MV100/device.mk` 里写死 `gsm.version.baseband=HiSTBAndroidV600R001C00SPC064`，
而本机（同系列 SPC065）运行的是 **Android 4.4.2**；另有社区文章明确写道
"这台盒子的硬件平台是海思 Hi3798MV100，官方 SDK 就是安卓 4.4，第三方做的安卓 5.1/6.0 是移植版"。

结论：**官方没有 MV100 的 5.x BSP，5.x 只存在于第三方移植包**。

## 3. 社区 5.1.1 固件证据

ZNDS 帖子（2026-02 更新）明确写：

> 适用芯片 海思 Hi3798MV100 … 系统版本 **Android 4.4.2/5.1.1**（海思专用定制系统），搭配当贝桌面 4.0
> 适用机型 MG100、MG101、UNT400B、新魔百和 M101 全系列
> 支持 RTL8188/RTL8723/MT7601 无线

与我们的机器高度相关：**同芯片 + 同款 RTL8188F WiFi**，说明 5.1.1 的驱动栈在这颗 SoC 上是跑通过的。

## 4. 与 Android TV 的距离

- 上述固件都是**盒子 ROM（当贝桌面）**，不是 Android TV（无 Leanback/TIF）
- 但 5.1 时代 **Android TV 与手机/盒子共用同一 AOSP 分支**，只要拿到 5.1 的盒子 ROM，
  加装 Leanback Launcher + TV Settings + TIF 桩的难度远低于 7.x 回移
- 关键仍是 **vendor HAL**：5.1 的 gralloc/HWC/OMX 版本与 4.4 不同，必须用 5.1 包里的库

## 5. 建议的 P0.5（下一步）

| 步骤 | 内容 | 产出 |
|---|---|---|
| 1 | 取得一个 MV100 的 5.1.1 通刷包（ZNDS/网盘），解包 `system.img` | 确认 `ro.build.version.release=5.1.1`、`ro.board.platform=bigfish` |
| 2 | 检查 `/system/lib/hw/` 下 `gralloc.*`、`hwcomposer.*`、`audio.*` 的版本与芯片标识 | 判断能否直接用于本机 |
| 3 | 比对分区表与 `fastboot/bootargs` 是否同构（mdmo1g） | 判断刷机可行性 |
| 4 | 若匹配：先原样刷入验证（用 006 的回滚兜底），再考虑加 ATV 组件 | 可用基线 |

## 6. 风险

- 社区包来源不明，可能夹带推广 App；需在隔离环境解包检查
- 5.1.1 仍偏旧：主流 App 已普遍要求 7.0+，兼容性改善有限（但比 4.4 明显）
- 若目标是"现代 Android TV 体验"，5.1 只是中间态
