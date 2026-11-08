# 029 — 发送器形态厘清（plan B 第 1 步产出）

> 状态：**已完成**。这是 `MAINLINE-PORTING.md` §5 第 1 步的产出。
> 目的：在选内核基线 / 取 histb 补丁之前，先确定「mv100 的 HDMI 输出到底由哪一路
> 发送器驱动」，避免绑错驱动导致「能编译但黑屏」。
> 方法：拉取 `histb-mainline/patches` 的补丁原文（本地存于项目内 `TMP/porting-patches/`，
> gitignored 不入库），逐份读 commit message、新建文件、DT binding 与板级 DTS。
> 本文自包含，结论可复现校验。

---

## 0. 结论先行（三方都要修正）

**mv100（含 EC6108V9C）的 HDMI 输出走 SiI9134 发射器**，由
`500-02` 补丁新建的 `drivers/gpu/drm/bridge/hi3798mv100-hdmi.c`（mv100 glue）
+ `sii9134.c`（发射器核心）驱动；SoC 侧 MMIO 窗口是 **`0x8ce0000`**，
DT compatible 为 **`hisilicon,hi3798mv100-hdmi`**。

由此三处旧表述需要修正：

| 出处 | 旧结论 | 判定 |
| --- | --- | --- |
| `docs/025` §8 | "mv100 用外挂 sii9134，不是 on-chip HDMI" | **方向正确**，但"外挂"措辞不精确（见 §3），且该节自身与 §3.4 矛盾 |
| `docs/027` §6 | 用 `0xf8ce0000` 常量"推翻"外挂 sii9134、认定片内 HDMI TX | **错误**，`0xf8ce0000` 是 hi3716cv200 的地址，不是 mv100（见 §2） |
| `docs/025` §8 / 本项目早前推断 | "600-17 的 `histb-hdmi.c` 是 mv200 片内发送器" | **正确**（§1 复核） |

**对 plan B 的直接影响**：mv100 应取 **bridge 链路**
（`500-01` dt-binding + `500-02` sii9134/hi3798mv100-hdmi.c + `600-18` video path up），
而不是 `600-17` 的 `histb-hdmi.c`（那是 mv200 片内 TX）。

---

## 1. `600-17`：片内 HDMI TX 是 mv200 的

补丁原文（`TMP/histb-ref/600-17-...patch`，commit message 首句）：

> "**The mv200 part** carries the HDMI transmitter on the SoC itself.
> Add the bridge driver for the on-chip TMDS transmitter."

- 新建 `drivers/gpu/drm/histb/histb-hdmi.c`（1392 行）+ `Kconfig`。
- Kconfig 里 `DRM_HISTB_VDP2` `depends on DRM && OF && ARM`（我们 32 位 ARM 路径适用），
  `DRM_HISTB_VDP4` 才是 `ARM64`。
- 结论：`600-17` = **mv200 片内 TMDS 发送器**，与 mv100 无关。
  `docs/025` §8 对它的定位是对的。

## 2. `600-18`：video path up 是 mv100 的，但打在 sii9134 链路上

补丁原文（`TMP/histb-ref/600-18-...patch`）：

> "**The mv100 transmitter** comes up with its video path down, so the panel
> stays black even with a live source. `VIDEO_PATH_CTRL` bit 0 blanks the
> outgoing video, and PHY register 0x09 depends on the die revision ..."

- 它修改的是 `drivers/gpu/drm/bridge/hi3798mv100-hdmi.c`（2 files, +223/-25）。
- 而 `hi3798mv100-hdmi.c` 这个文件的**创建者**正是 `500-02`（见 §3）——
  这补上了 `docs/025` §8 里"该文件的创建补丁不在本地已存的 4 个补丁里"的缺口。
- 结论：`600-18` 属于 **mv100 链路**，且它作用的 `hi3798mv100-hdmi.c` 属于 sii9134
  bridge 链路，**不是** `600-17` 的 `histb-hdmi.c`。
  这一点印证 `docs/025` §2.2 提到的「video path 默认关闭 → 能编译但黑屏」类坑。

## 3. `500-02` / `500-01`：mv100 = SiI9134，`0x8ce0000`

`500-02`（`TMP/porting-patches/500-02-...patch`，commit message）：

> "**The mv100 board reaches its panel through a SiI9134 transmitter.**
> Add the bridge core and the mv100 glue, programming the AUDP mode the link needs."

- 新建 3 个文件：`sii9134.c`（SiI9134 HDMI 1.4 发射器核心，1643 行）、
  `sii9134.h`、`hi3798mv100-hdmi.c`（mv100 glue）。
- `sii9134.c` 用 regmap，注释写明「三组 byte 寄存器 bank、4 字节 MMIO stride；
  TMDS PHY 窗口与 DVI encoder 位置由 `struct sii9134_phy_ops` 按集成方式注入」，
  并带 master DDC（I2C adapter，用于 EDID）。
  → 说明这是**通过 SoC 内的 MMIO 窗口访问的 SiI9134 IP**，不是 I2C 上挂的一颗
  独立芯片。所以 `docs/025` §8 的"外挂"措辞不精确，但"走 sii9134 发射器"这一
  实质判断正确。

`500-01` dt-binding（`hisilicon,hi3798mv100-hdmi.yaml`）：

- compatible：`hisilicon,hi3798mv100-hdmi` / `hisilicon,hi3716cv200-hdmi`。
- **mv100 示例节点地址 `reg = <0x8ce0000 0x10000>`**；
  **hi3716cv200 示例节点才是 `reg = <0xf8ce0000 0x10000>`**。
- clock `HI3798MV100_HDMI_CTRL_CLK` / `..._PHY_CLK`；reset `base`/`bus`/`phy`；
  有 `ports` 端点连到 VDP；带 `#sound-dai-cells`（HDMI audio）。

`910-01` SoC dtsi（`TMP/porting-patches/910-01-...patch`）第 469 行起：

```
hdmi: hdmi@8ce0000 {
    compatible = "hisilicon,hi3798mv100-hdmi";
    reg = <0x8ce0000 0x10000>;
    ...
    status = "disabled";
    ports { port@0 { hdmi_in_vdp: endpoint { remote-endpoint = <&vdp_out_hdmi>; }; }; };
};
```

`910-02` EC6108V9C 板级 DTS（`TMP/histb-ref/910-02-...patch`）：

- 第 339 行 `&hdmi { ... }` 打开该节点；第 343 行 `&vdp { memory-region = <&media_cma>; }`
  把显示控制器接到保留的连续内存池；第 383 行 audio `model = "hi3798mv100-hdmi"`，
  第 390 行 `sound-dai = <&hdmi>`。
- 另有 `i2c_hdmi: i2c-hdmi`（GPIO bit-bang，默认 disabled）与注释「HDMI block keeps
  the DDC pins to itself」——即 EDID 可由发射器自带的 DDC 走，不必外挂 I2C 适配器。

### 关于 `docs/027` §6 的误判

`docs/027` §6 依据「备份里有 `0xf8ce0000` 常量、`0xf8cc0000`、hiboot 的
`HDMI_Display`/`TX_PHY_*`」认定本板是**片内 HDMI TX**、并据此推翻外挂 sii9134。
现在有了补丁原文可以定性：

- `0xf8ce0000` 在 histb 的 dt-binding 里明确属于 **hi3716cv200**（`cv200` 系列是
  高安/另一 SoC，社区讨论里也提到 cv200 与 mv100/mv200 不同）。
- mv100 用的是 **`0x8ce0000`**（注意没有前导 `f8`，是 SoC 内不同的地址映射）。
- 备份里出现 `0xf8ce0000` 更可能是 SDK 通用头里对多个 chip 的条件编译常量
  （`docs/027` §6.1 自己也提到 `drv_reg_proc.h` 有 `CHIP_TYPE_hi3798mv100` 分支、
  `HDMI_TX_BASE_ADDR=0xf8ce0000`），或属于 HDMI 输入/RX 侧，不能据此断定 mv100
  **输出**发送器的形态。
- SiI9134 字面量 0 命中也不能反证：驱动以厂商 IP 名 / 内部封装形式存在，
  `500-02` 的 glue 文件就叫 `hi3798mv100-hdmi.c`，并不带 `sii9134` 字样在板级节点里。

→ **`docs/027` §6 的"推翻"不成立，应撤销**；但它保留的「先厘清再定基线」
这一方法论要求本身是对的，正是本文在做的事。

---

## 4. 对 plan B 的落地决策

### 补丁基线（mv100 / EC6108V9C = ARM 32-bit）

取 **bridge 链路**：

| 补丁 | 作用 | 必需 |
| --- | --- | --- |
| `500-01` | `hisilicon,hi3798mv100-hdmi` dt-binding | 是 |
| `500-02` | `sii9134.c` 核心 + `hi3798mv100-hdmi.c` glue | 是 |
| `600-18` | video path 使能 + PHY 按 die revision 配置 | 是（否则黑屏） |
| `600-01`~`600-13` | VDP v2 显示引擎 / plane / core | 是（`hdmi_in_vdp` 的上游） |
| `600-19`/`600-20` | DRM build 整合（注意含 VDP4/ARM64 项，需裁剪） | 视基线裁剪 |
| `910-01`/`910-02`/`910-03` | SoC dtsi + EC6108V9C 板级 DTS + VPSS | 是 |
| `910-05`/`910-06`/`910-08` | hi3798 family include / 构建 EC6108V9C dtb / CPU 描述 | 是 |
| `500-02` 相关 clk/reset `400-01`/`400-02`（CRG） | HDMI ctrl/phy clock | 是 |

**不取** `600-17` 的 `histb-hdmi.c`（mv200 片内 TX）——除非将来确认同板并存第二路，
目前证据不支持。

### 内核基线（回到 `MAINLINE-PORTING.md` §4）

本节厘清**不改变**基线选择本身，但强烈支持 **B（histb-mainline 7.3/7.4 树）**：
因为 mv100 所需的 DRM VDP2 + sii9134 bridge + CRG + 板级 DTS 是一整套互相依赖的
补丁（154 个 pending 里的显示子集约 20+ 个），在 6.3 上逐个反向移植的成本远高于
直接采用已在同一块 EC6108V9C 点亮 HDMI 的上游树（`docs/028` §6）。
`docs/025` §8 「反向移植到 6.3 更重」的判断依然成立，且现在有了更具体的理由。

### 下一个动作（§5 第 2 步）

1. 确定基线（建议 B），据此确定内核源码接入方式（用户已 fork histb patches 仓库）。
2. 把上表补丁子集按顺序整理成可应用的 series，先做**编译验证**（CI，不本地构建镜像）。
3. 保留我们的 cmdline / 8 分区 / pstore / 绿带标记，移植到上游树的板级 DTS 上。
4. QEMU 跑 rootfs 启动基线，再上真机。

---

## 5. 复现

- 补丁清单：`TMP/histb-pending.json`（154 项）/ `TMP/histb-hack.json`（23 项）。
- 本次下载原文：`TMP/porting-patches/`（`500-01`、`500-02`、`600-19`、`600-20`、
  `910-01`、`910-06`），加上既有 `TMP/histb-ref/`（`600-17`、`600-18`、`910-02`、
  `910-03`）。均在项目内、gitignored，未入库。
- 来源：`histb-mainline/patches` 仓库 `pending-7.4/` 分支 `master`，补丁 commit
  message 与 DT binding 示例为判据。

## 6. 需要同步修正的文档（后续提交）

- `docs/025` §8：把被删除线标记的"外挂 sii9134"结论**恢复为正确**，改为引用本文，
  说明措辞修正（MMIO 窗口访问的 SiI9134 IP，非独立 I2C 芯片）。
- `docs/027` §6：撤销"推翻 `docs/025` §8"的结论，标注 `0xf8ce0000` 归属
  hi3716cv200、mv100 为 `0x8ce0000`；保留其证据与「先厘清」的方法论。
- `MAINLINE-PORTING.md` §3/§4/§5：把"发送器形态尚需厘清"更新为"已厘清 = bridge
  链路"，并把第 1 步标为完成。
