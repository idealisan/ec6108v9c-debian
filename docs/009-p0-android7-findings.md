# P0 结果：MV100 的 Android 7 BSP 是否存在

- 分支：`android7`
- 日期：2026-11-03
- 方法：公开仓库检索 + SDK 文档核对 + 设备自身版本信息交叉验证
- 关联：`008-android7-plan.md`（P0 门槛：找到可验证的真·MV100 Android 7 BSP）

## 1. 结论

**P0 门槛未通过。**

- 公开可查的 HiSilicon Android SDK 只有 **HiSTBAndroidV600R001** 系列，其兼容列表明确覆盖 **Hi3798MV100 / Hi3796MV100**；
- 设备自身的 `gsm.version.baseband` = `HiSTBAndroidV600R001C00SPC065`，而系统是 **Android 4.4.2**
  → V600 就是这台机器所属的 4.4 系列，**不是 7.x**；
- GitHub 全站检索 `HiSTBAndroidV700`：**0 个结果**；检索 `HiSTBAndroid`：仅 4 个仓库，全部为 V600；
- 社区所谓"MV100 刷 7.1.2"的文章（如 hqwc）没有可验证的下载源，且已知可下载的 MV100 安卓包都是
  **当贝桌面风格的盒子 ROM**（多数仍是 4.4 改版），**没有 Android TV 版本**；
- 唯一"Hi3798M + Android 7.1"的成品（MECOOL K6）是高一级的 mv200 平台，不能直接用于 mv100。

## 2. 证据明细

| 来源 | 内容 | 判定 |
|---|---|---|
| GitHub `wudilsr/HiSTBAndroidV600R001C00SPC064` | SDK 文档包，`hardware/` 下有 `Hi3798MV100`、`Hi3796MV100` 目录，兼容列表列出 Hi3798MV100 BGA/QFP | MV100 的官方 Android 线 = V600 |
| 同上 `release notes/HiSTBAndroidV600R001C00SPC064版本描述文件.doc` | 版本序列 SPC030→SPC064，无 7.x 字样 | 无 7.x |
| 本机 `getprop gsm.version.baseband` | `HiSTBAndroidV600R001C00SPC065`，系统 4.4.2 | V600 ↔ 4.4 |
| GitHub 搜索 `HiSTBAndroidV700` | total_count = 0 | 无公开 7.x SDK |
| GitHub `qinxiongxu/HiSTBAndroid` | 部分源码树，`device/hisilicon/{Hi3798MV100,Hi3796MV100,bigfish}`，平台名 `bigfish` 与本机一致 | 仍是 V600/4.4 体系 |
| 社区帖子（histb/ZNDS/恩山） | MV100 安卓包 = 当贝桌面盒子 ROM；多数为 4.4 精简版；链接多失效或需网盘登录 | 无 ATV、无 7.x |
| `hqwc.cn` "MV100 刷 7.1.2" | 无可下载产物，内容疑为 AI 生成 | 不可采信 |

## 3. 对计划的影响

- **路线 A（改现成 MV100 7.1 ROM）：无输入，不可执行**；
- **路线 B（以 V700 回移）**：前提改为"先找到 mv200/mv300 的 V700 源码"，
  目前公开渠道同样没有 → 需先完成 P0.5（搜索 V700 源码镜像）；
- **路线 C（AOSP + 4.4 vendor）**：已排除（HAL 不兼容）。

## 4. 建议的三个选项

| 选项 | 说明 | 成本 | 结果 |
|---|---|---|---|
| ① 保留 Debian + Kodi/VLC | 已有可用系统，媒体中心体验接近 ATV | 低 | 不是 Android，但 App 生态（Linux 侧）可用 |
| ② 刷 4.4 当贝盒子 ROM | 去 IPTV 限制、可装第三方 APK | 低 | 仍是 4.4，解决不了"新 App 要 7.0+" |
| ③ 换硬件（S905X3/X4 等） | Android TV 9/11 生态成熟 | 中 | 真正解决需求 |
| ④ 继续追 7.1（P0.5） | 先找 mv200/300 的 V700 源码，评估回移到 mv100 | 高（人月级） | 成功率低：MV100 无 4.4 以上内核基线，VPU/HAL 全需重做 |

## 5. 如果仍要继续：P0.5 待办

1. 检索 mv200/mv300 的 `HiSTBAndroidV700` 源码镜像（GitHub/Gitee/网盘）
2. 若找到：核对是否含 `device/hisilicon/hi3798mv300`、内核 4.4 与 OMX/HWC 版本
3. 评估把 mv300 的 7.x BSP 裁到 mv100 的工作量（内核 3.10→4.4、VPU 驱动、DDR）
4. 结论若为"人月级"，建议转向选项 ③

## 6. 备注

社区固件的常见发布形态是"U 盘卡刷包"（bootargs.bin + fastboot.bin + recovery.img + update.zip），
与我们的刷机机制同源；即便将来找到 7.x 包，也可复用 `001/006` 的引导与回滚流程。
