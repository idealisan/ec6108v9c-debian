# Android 5.x 资源复核与"验真"方法

- 分支：`android7`
- 日期：2026-11-03
- 起因：社区"5.1.1 通刷包"有人反馈只是改了版本号，实际仍是 4.4

## 1. 复核结论

| 说法 | 判定 | 依据 |
|---|---|---|
| 官方有 MV100 的 5.x BSP | **否** | `HiSTBAndroidV600R001C00SPC064` 的 `device/hisilicon/Hi3798MV100/device.mk` 写死 `gsm.version.baseband=HiSTBAndroidV600R001C00SPC064`，而本机（SPC065）是 **Android 4.4.2**；社区文章亦称"官方 SDK 就是安卓 4.4，5.1/6.0 是移植版" |
| 社区存在 MV100 的 5.1.1 包 | **存在但不可信** | ZNDS 多个帖子标"Android 4.4.2/5.1.1"；但同一份列表里 5.1.1 的机型多标注为 mv310/MSO9380；确有人反馈"只改了版本号" |
| 5.1.1 是 MV100 的"甜点版本" | 有这种说法 | 社区文章称"MV100 上 5.1.1 最合适，再高就卡"，但无一手验证 |

**结论：没有干净的官方 5.x 底座；5.x 只能来自第三方移植包，必须逐个验真。**

## 2. 验真工具（本次新增）

`scripts/inspect-rom.sh` + `scripts/unsparse.py`：给一个刷机包（zip 或目录），自动输出

- 包内镜像清单
- `system.img` 的真实 `ro.build.version.release` / `sdk` / `fingerprint` / `ro.board.platform`
- `/system/lib/hw/` 下的 gralloc / hwcomposer / audio 等 HAL 库清单
- `boot.img` 的内核大小与 `Linux version ...` 字符串

用法：

```sh
scripts/inspect-rom.sh ~/Downloads/某个5.1.1包.zip
```

判定标准：

| 检查项 | 真 5.1 | 假 5.1（改版本号） |
|---|---|---|
| `ro.build.version.release` | 5.1 / 5.1.1 | 5.1（但下面几项对不上） |
| `ro.build.version.sdk` | **22** | 19（4.4 的 API 级别） |
| `ro.build.fingerprint` | 含 `/LMY` 或 `5.1.1` | 含 `KOT49H` / `4.4.2` |
| `/system/lib/hw/hwcomposer.*` | 5.x 版本（HWC 1.4） | 4.4 版本 |
| `boot.img` 内核 | 3.10/3.18，构建日期 2015+ | 2014 年的 3.10 |

> API level 是最硬的指标：改 `build.prop` 里的人很容易，但 `sdk=22` 需要整套 5.1 框架。

## 3. 如果拿到"真 5.1"包，下一步

1. 用它刷一台（需同 mdmo1g 分区），先验证能否启动（有 006 回滚兜底）
2. 若可启动：列出可用/不可用功能（WiFi、BT、遥控、硬解、HDMI）
3. 再评估加 Android TV 组件（Leanback/TV Settings/TIF）的可行性

## 4. 其他可能的 5.x 来源（待验证）

| 来源 | 说明 | 状态 |
|---|---|---|
| 大麦 DM4036 出厂 5.1 | 社区文章称该机型（MV100）出厂即 5.1 | 未验证，且文章有明显事实错误（写成 Cortex-A9），存疑 |
| 咪咕 MG100/MG101 通刷包 | 标 4.4.2/5.1.1，需网盘 | 待验真 |
| E900-S 系列 | 5.1.1 版本集中在 **mv310**，mv100 版本为 4.4.2 | 基本排除 |
| HiSTBAndroid V600R003 | 面向 mv200/300（wpa_supplicant N_7.0），不含 mv100 | 排除 |

## 5. 建议

- 不要直接刷"标称 5.1.1"的包，先跑 `inspect-rom.sh`；
- 若验出 `sdk=19`（4.4），该包与现有系统无差别，没有移植价值；
- 若确为 `sdk=22`，再考虑作为 5.x 底座，并评估 ATV 化。
