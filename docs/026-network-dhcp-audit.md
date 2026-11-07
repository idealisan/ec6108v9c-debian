# 026 — 网络 / DHCP 侧审计（"路由器看不到新 IP"）

## 0. 结论先行

用户怀疑"内核其实起来了，只是 DHCP / IP 分配没成功，所以 SSH 和路由器都
看不到现象"。逐层核查后的结论：

- **用户态 DHCP 配置是对的**：`systemd-networkd` 已 enable，
  `/etc/systemd/network/10-eth0.network` 有 `DHCP=yes`，且 networkd 会等待
  carrier 并持续重试租约（比 `ifupdown` 的 `dhclient` 一次性失败更稳）。
- **以太网驱动是编进去的**：`hi3798mv100_defconfig` 第 707/735/758 行分别是
  `CONFIG_NETDEVICES=y`、`CONFIG_HISI_FEMAC=y`、`CONFIG_MDIO_HISI_FEMAC=y`。
- **DTS 节点也已启用**：板级 `hi3798mv100-ec6108v9c.dts` 末尾自带
  `&eth0 { status = "okay"; };`；`hi3798mv100.dtsi` 里 `eth0: ethernet@9840000`
  虽是 `disabled`，但被板级覆盖。
- **时钟 / 复位 provider 在**：`crg` 节点 compatible 是
  `hisilicon,hi3798mv100-crg`；`COMMON_CLK_HI3798` 的 Kconfig 是
  `default ARCH_HISI` 且 `select RESET_HISI`，而 defconfig 有
  `CONFIG_ARCH_HISI=y`。femac probe 需要的 `devm_clk_get` / `reset_control_get`
  能满足。

也就是说，**没有发现"DHCP 配置错误"这一层的问题**。如果内核真的启动到
`systemd-networkd`，`eth0` 应该会创建并尝试拿地址。因此"无 IP"本身不能证明
网络坏了——它同样（而且更简洁地）解释为**内核根本没启动**，即 `docs/024` §6
里的 A 分支。两者要靠屏幕判据分开，见 §4。

### 审计过程中修正过的两次误判（记录以免重走）

1. 一开始只 grep `configs/kernel/ec6108v9c.config`，看到没有 `NETDEVICES` /
   `HISI_FEMAC` 就判断"没编 MAC 驱动"。**错**：该文件只是**增量 fragment**，
   基 `hi3798mv100_defconfig` 已开着这些符号，`build-kernel.sh` 的
   `scripts/config` 合并不会关掉它们。
2. 随后 grep `patches/kernel/` 没找到 ethernet 节点，判断"DTS 没描述网卡"。
   **错**：节点在子模块 `hi3798mv100.dtsi`，且板级 DTS 末尾有 `&eth0` 覆盖；
   另一次 `grep -rn '&eth0'` 被 `head -20` 截断，输出里全是 kirkwood / armada
   的 hit，把 hisi 那条遮住了。
   **教训**：查内核能力必须同时看 `defconfig` + `dtsi` + 板级 `dts` + fragment，
   且长输出不要过早截断。

## 1. 逐层核查表

| 层 | 位置 | 状态 |
| --- | --- | --- |
| DHCP 客户端包 | `build-rootfs.sh` debootstrap 包列表含 `isc-dhcp-client` | OK |
| 网络服务 | `multi-user.target.wants/systemd-networkd.service` 软链 | OK |
| `networking.service` | 被 `ln -sf /dev/null` 屏蔽，避免与 networkd 抢接口 | OK |
| `.network` 规则 | `10-eth0.network` / `20-wlan.network`，`DHCP=yes` | OK（本轮加固） |
| MAC 驱动 | defconfig `CONFIG_HISI_FEMAC=y` | OK |
| MDIO 驱动 | defconfig `CONFIG_MDIO_HISI_FEMAC=y`，`mdio-hisi-femac.c` | OK |
| PHY | `phy@1` 无 compatible → PHYLIB generic PHY | 待真机确认 |
| DTS 节点 | `&eth0 { status = "okay"; }` | OK |
| 时钟 / 复位 | `COMMON_CLK_HI3798` / `RESET_HISI`（ARCH_HISI 带出） | OK |
| 内核 IP 自动配置 | fragment 有 `CONFIG_IP_PNP_DHCP=y`，但 cmdline 无 `ip=dhcp`，故不生效 | 无害 |

## 2. 本轮实际修了什么（都是稳健性缺口，不是"修 bug"）

1. **可预测网卡名**。Debian 的 udev 可能把 FEMAC 接口从 `eth0` 改名（如
   `end0`），而 `[Match] Name=eth0` 精确匹配会永不命中 → networkd 完全不配置
   该接口 → 无 IP。在 `configs/partition-layout.env` 的 `KERNEL_CMDLINE_NO_MEM`
   加 `net.ifnames=0` 锁定名字；因为该文件是 DTB `/chosen/bootargs` 与 p2
   运行时 env 的**单一来源**，两处自动同步，不会漂移。
2. **不等 carrier**。内部 FEPHY 用 generic PHY 驱动时可能不及时（或根本不）
   上报 link，而 networkd 默认要等到 carrier 才发起 DHCP。`10-eth0.network`
   加 `ConfigureWithoutCarrier=yes`，并把 `[Match]` 放宽成 `Name=eth*`、
   `DHCP=ipv4`；`20-wlan.network` 放宽成 `Name=wl*` 以兼容 `wlx*` / `wlan0`。
3. **显式声明 + CI 审计**。`configs/kernel/ec6108v9c.config` 显式写出
   `NET_VENDOR_HISILICON` / `HISI_FEMAC` / `MDIO_HISI_FEMAC` / `PHYLIB` /
   `NETDEVICES`（幂等保险），并在 `build-kernel.sh` 的
   `verify key options` grep 里加入这些符号以及 `COMMON_CLK_HI3798` /
   `RESET_HISI`。此前 CI 日志**从未验证过网卡选项**，只能靠推理；下一版日志会
   直接给出答案。

## 3. 内核版本说明

本仓库**并未**切换到 7.4 / histb-mainline。`.gitmodules` 指向
`loonpn/ec6108v9c-linux-kernel`，子模块 `Makefile` 是
`VERSION=6 / PATCHLEVEL=3 / EXTRAVERSION=-rc5`，`build-kernel.sh` 使用
`hi3798mv100_defconfig`。7.4 只做到 `docs/025` 的调研，迁移未实施（用户明确
要求先出可刷产物、暂缓维护）。因此本文所有结论针对的就是**当前刷机包里那个
6.3-rc5 内核**。

## 4. 判据：怎么把"内核没起来"和"网络没通"分开

刷本版后按 `docs/024` §6 的两个可见信号 + 路由器列表一起看：

| 屏幕 | 路由器新 IP | 结论 |
| --- | --- | --- |
| 停在阶段 logo（`0-4`..`3-4`） | 无 | 刷机链在某一步断了，先按阶段图定位写入 |
| `Debian Linux`，无绿带 | 无 | 内核没跑到 HDMI 驱动的 initcall（A）→ 查 p6 / DTB / `mem=` |
| 绿带出现 | 无 | 内核确实启动了（B/C）→ 此时才轮到查 femac PHY、carrier、DHCP |
| 绿带 + 内核文字 | 有 | 全链路通，可直接 SSH 读 `dmesg` / pstore |

关键：**只有先确认内核活着（绿带），"网络没通"这个假设才值得继续投入**。
否则在 DHCP 上反复加配置只是在给一个根本没启动的内核调参数。

## 5. 参考

- `scripts/build-rootfs.sh`（网络服务与 `.network` 规则）
- `configs/kernel/ec6108v9c.config` / `arch/arm/configs/hi3798mv100_defconfig`
- `drivers/net/ethernet/hisilicon/hisi_femac.c`、`drivers/net/mdio/mdio-hisi-femac.c`
- `arch/arm/boot/dts/hi3798mv100.dtsi` 的 `eth0` / `mdio0` / `crg` 节点
- `docs/024` §6（A/B/C 判据与绿带启动标记）
