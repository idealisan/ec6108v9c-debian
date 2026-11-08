# 044 — 主线 6.3 内核「从未连上网络」问题分析（在线对照 + 源码核查）

> 2026-11-08。分支 `main`（6.3）。用户指出：刷 6.3 主线内核的系统**从未成功连上网络**。
> 本轮在社区 Ubuntu（能联网、4.4 内核）在线对照 + 6.3 内核源码/DTS 静态核查，
> 判断「无 IP」的真正根因。承接 `docs/026`（配置层审计）。
>
> 方法：SSH 只读探测社区真机网络基线；grep 6.3 内核 DTS/驱动/defconfig/Kconfig；
> 模拟 `apply-dts-placeholders.py` 验证 ramoops 注入。不刷机、不改真机、不构建镜像。

---

## 0. 结论先行

> **「无 IP」不能证明网络驱动坏了；更简洁、且与本轮全部证据一致的解是
> 「主线 6.3 内核根本没启动到 userspace」**。这与 `docs/026 §0`、`docs/024 §6` 一致。
>
> 静态网络配置层（DHCP / systemd-networkd / FEMAC / MDIO / PHYLIB / DTS / 时钟 / 复位）
> **逐项齐全，没有发现确定会导致「连不上」的配置缺口**。
> 因此网络问题的诊断**必须先依赖显示/pstore 打通**，否则无法区分
> 「内核没起来」与「内核起来了但 eth0 没配置」。

`docs/043`（本轮显示修复 + pstore 诊断）出的这一版 CI，正是这个前置：
它让驱动把 `VO layer0` / `HANDOFF` 参数打进 pstore，并把 ramoops 注入 DTB。

---

## 1. 社区真机网络基线（能联网的 4.4 内核，在线实测）

| 项 | 值 |
|---|---|
| eth0 状态 | `UP`, `LOWER_UP`, carrier=1, 100 Mb/s full duplex |
| IP | `192.168.3.238/24`，默认路由 `via 192.168.3.1 dev eth0 proto dhcp` |
| MAC | `00:11:22:33:44:55`（= U 盘 `bootargs.bin` 里 `ethaddr`） |
| **网卡驱动** | **`hieth`**（`/sys/class/net/eth0/device/uevent`: `DRIVER=hieth`, `OF_COMPATIBLE_0=hisilicon,hieth`, `OF_FULLNAME=/soc/hieth@f9840000`） |
| DT 节点 | `/proc/device-tree/soc/hieth@f9840000`：compatible=`hisilicon,hieth`，含 `hieth_phy@0`、`phy-handle`、`clocks`、`interrupts` |
| dmesg | `libphy: himii: probed` → `hi_eth: attached port 0 PHY 1 to driver Generic PHY` → `[28.8s] eth0: Link is Up - 100Mbps/Full` |

→ **[观察] 社区用的是 HiSilicon 私有 `hieth` + `himii` MDIO 驱动**，不是主线 `hisi_femac`。
这是一条重要对照：两代内核走的是**完全不同的网卡驱动栈**。

---

## 2. 主线 6.3 的网卡栈（源码核查）

| 项 | 值 | 判定 |
|---|---|---|
| SoC dtsi 节点 | `eth0: ethernet@9840000`，`compatible = "hisilicon,hisi-femac-v2"` | ✅ |
| 驱动 of_match | `hisi_femac.c:950-952`：`hisi-femac-v1/v2`、`hi3516cv300-femac` | ✅ **与 DTS 匹配，会 probe** |
| 板级覆盖 | `&eth0 { status = "okay"; }` | ✅ |
| MDIO 节点 | `mdio0: mdio@9841100`，`compatible = "hisilicon,hisi-femac-mdio"`，**无 status=disabled（默认启用）** | ✅ |
| PHY 节点 | `phy1: phy@1 { reg = <1>; mac-address = [00...]; }`，无 compatible → generic PHY | ⚠️ 待真机确认 |
| `phy-handle` | `eth0` 指向 `<&phy1>`，`phy-mode = "mii"` | ✅ |
| 时钟 / 复位 | `clocks = <&crg HISTB_ETH0_MAC_CLK>`；`resets = <&crg 0xcc 4>, <&crg 0x120 4>`；`reset-names="mac","phy"` | ✅ |
| defconfig | `CONFIG_NETDEVICES=y` (707)、`CONFIG_HISI_FEMAC=y` (735)、`CONFIG_MDIO_HISI_FEMAC=y` (758) | ✅ |
| Kconfig | `HISI_FEMAC` → `select PHYLIB` + `select RESET_CONTROLLER`；mdio 驱动 `drivers/net/mdio/mdio-hisi-femac.c` | ✅ |
| fragment | `ec6108v9c.config` 显式 `NET_VENDOR_HISILICON/HISI_FEMAC/MDIO_HISI_FEMAC/PHYLIB/NETDEVICES` | ✅（`docs/026 §2` 补的幂等保险） |

→ **[观察] 之前担心的「`hisilicon,hieth` vs `hisi-femac` compatible 不匹配导致驱动不 probe」不成立**：
主线 DTS 用的是 `hisi-femac-v2`，与 `hisi_femac.c` 的 of_match 精确匹配。
社区 `hieth` 是另一套（4.4 私有栈），两者不互相影响。

### 2.1 probe 的脆弱点（`hisi_femac.c:768-894`）

`hisi_femac_drv_probe` 的关键失败点，按可疑度排序：

1. **`of_phy_get_and_connect()` (833)**：依赖 `phy-handle=<&phy1>` + `mdio0` 总线把 `phy@1` 枚举出来。
   `phy@1` 无 `compatible`，走 generic PHY；社区 4.4 同样用 `Generic PHY` 且能起来，说明硬件 PHY 可被通用驱动驱动。
   但如果主线 `mdio-hisi-femac` 的 `of_mdiobus_register` 没成功枚举 `phy@1`，这里返回 NULL → `connect to PHY failed!` → probe 失败 → **无 eth0**。
2. **`devm_reset_control_get(dev, "mac")` (813)**：需要 `crg` reset provider + `resets` 属性。`CONFIG_RESET_HISI`/`COMMON_CLK_HI3798` 由 `ARCH_HISI` 带出（`docs/026 §0`）。
3. **`devm_clk_get(NULL)` (800)** + `clk_prepare_enable` (807)：需要 `crg` clock provider。
4. `of_get_ethdev_address()` (844) 失败只 warn 随机 MAC，不致命。

→ **[推断]** 即使内核起来了，最可能的失败点是 **MDIO 枚举 / PHY connect**，
而不是 MAC 驱动本身。这只能靠 pstore 里 `connect to PHY failed!` / `failed to get clk` 之类的
`dev_err` 来确认——再次说明 pstore 是前置。

---

## 3. 用户态网络配置（`docs/026` 已审计，复核无变化）

`scripts/build-rootfs.sh`：
- `10-eth0.network`：`[Match] Name=eth*`、`DHCP=ipv4`、`ConfigureWithoutCarrier=yes`（115-125 行）
- `20-wlan.network`：`Name=wl*`（127-134 行）
- `systemd-networkd.service` 软链到 `multi-user.target.wants`（136 行），`networking.service` 屏蔽（141 行）
- cmdline `net.ifnames=0`（`configs/partition-layout.env`）锁定 `eth0` 不被 udev 改名

→ **[观察] 配置全对**。若 `eth0` 存在且内核到 userspace，networkd 会发起 DHCP。

---

## 4. pstore 诊断链（这次出包是否拿得到日志）

`docs/024 §3.4` 曾指出「pstore 编进内核但没激活」。本轮验证现状：

- `ramoops.dtsi`：`ramoops@30000000 { reg = <0x30000000 0x100000>; no-map; }`
- `apply-dts-placeholders.py`：`FB_BASE` 为空时注入 `reserved-memory` 容器 + ramoops_child
- 占位符 `__FB_BLOCK__` 由 **patch 0001** 加入板级 DTS（`0001-...patch:31`）
- **`build-kernel.sh` 顺序正确**：先 `git apply` patch 0001（62-73 行），再跑占位符脚本（85 行）

模拟验证（用打了 patch 的 DTS）：注入后 DTB 里确有 `reserved-memory` / `ramoops@30000000` /
`compatible = "ramoops"` / `reg = <0x30000000 0x100000>`。
ramoops 地址 768 MiB 不与内核(<32 MiB)、显存(~965 MiB) 冲突。

> 一次「grep 不到 ramoops」的假警报源于**用未打 patch 的原始 DTS 模拟**；
> CI 会先 apply patch，占位符存在，注入成功。按 `docs/033` 记录以免重走。

→ **[观察] 这一版（`docs/043`）出包能拿到 pstore 日志**，
`docs/043` 里新增的 `hi3798-fb: VO layer0` / `HANDOFF` 打印会落进 `dmesg-*`。

---

## 5. 判据：如何区分「内核没起来」与「网络没通」

刷入本版后，重启回社区系统读 `/sys/fs/pstore/`：

| 现象 | 判定 |
|---|---|
| pstore 为空、无 `hi3798-fb` 打印 | 内核没跑到 `subsys_initcall` → **A 分支（内核没起来）**，网络问题无从谈起 |
| pstore 有 `HANDOFF` 但无 `hisi-femac` / `eth0` 相关 | 内核起来了、显示驱动跑了 → 查 MAC/MDIO probe（`connect to PHY failed!`） |
| pstore 有 `eth0: Link is Up` 但仍无 IP | 内核 + 网卡都好 → 查 userspace DHCP（networkd 日志） |
| HDMI 出 TTY 文本 | 直接肉眼看到启动阶段与报错（本版目标） |

→ 这正是用户要的「看到原因、看到阶段」。

---

## 6. 结论与下一步

1. **不要盲目改网络配置**——`docs/026` 与本轮核查都表明配置层无确定缺口，
   在「内核是否起来」未判定前改网络会重蹈「在未知上叠改造」（`docs/024` 教训）。
2. **先落实显示/pstore 前置**（`docs/043` 这一版 CI 已发），刷入后按 §5 判据读日志。
3. 若日志证明内核起来了但 `eth0` 没出，则按 §2.1 顺序查 MDIO/PHY connect，
   并对照社区 `hieth` 的 `himii` MDIO 初始化（`docs/035` 的 MMIO 序列方法论可复用）。
4. 最早期日志仍要靠绿带标记 + pstore（`docs/042 §0` 的时机边界）。

---

## 7. 合规

- SSH 只读探测社区真机；本机只做 grep / 模拟占位符注入；
  未刷机、未改真机、未构建镜像、未删文件、未联网下载、未访问项目外目录。
- 描述本地资源用仓库内相对路径，**不含本机绝对路径 / 用户名 / 卷名 / IP / 凭据**。
- 结论按 `docs/033 §2` 标注 `[观察]` / `[推断]`；假警报留痕。
- 提交时显式 `git add <具体路径>`，提交后核对 `git show --stat`；纯 `docs/` 改动不触发 build workflow。
