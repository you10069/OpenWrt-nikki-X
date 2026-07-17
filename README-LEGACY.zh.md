# Nikki Legacy：OpenWrt 21.02 / firewall3 / xtables

这是基于 [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 改造的实验性 legacy 分支，目标是让 Nikki 在 **OpenWrt 21.02 类系统、firewall3、iptables 和 ip6tables** 环境中运行，同时完全移除运行时 `ucode`、`firewall4` 和 nftables 依赖。

## Legacy v2 范围

已实现：

- IPv4 与 IPv6 透明代理；
- LAN 客户端 TCP `REDIRECT`；
- LAN 客户端 UDP `TPROXY`；
- 路由器本机 TCP `REDIRECT`；
- 路由器本机 UDP：`OUTPUT MARK → policy routing → PREROUTING TPROXY`；
- IPv4/IPv6 路由器和 LAN DNS 劫持；
- 按 OpenWrt 网络接口、客户端 IPv4、IPv6、MAC、路由器用户和用户组进行访问控制；
- IPv4/IPv6 保留地址、中国大陆地址、DSCP 和 fwmark 绕过；
- Mihomo `routing-mark` 防回环；
- firewall3 script include，在防火墙重载后恢复双栈规则；
- 无 ucode 的 Mihomo 配置生成；
- 无 rpcd-ucode 的 LuCI 辅助后端。

暂未实现：

- TCP TPROXY；
- TUN 数据面；
- cgroup 访问控制；
- 多 WAN、策略出口和复杂硬件加速兼容；
- 正式发布级别的全设备回归测试。

IPv6 代理和 IPv6 DNS 劫持在默认配置中保持关闭，需要在 LuCI 中明确启用。启用 IPv6 DNS 劫持时，Mihomo DNS 必须监听 IPv6 地址，默认使用：

```text
[::]:1053
```

## 数据路径

IPv4 与 IPv6 使用相同结构，只是分别由 `iptables` 和 `ip6tables` 执行。

```text
LAN TCP
  → nat/PREROUTING
  → NIK_NAT_PRE_TCP_V4 或 NIK_NAT_PRE_TCP_V6
  → REDIRECT → Mihomo

LAN UDP
  → mangle/PREROUTING
  → NIK_MGL_PRE_CTRL_V4 或 NIK_MGL_PRE_CTRL_V6
  → NIK_MGL_PRE_TPROXY_V4 或 NIK_MGL_PRE_TPROXY_V6
  → TPROXY → Mihomo

Router TCP
  → nat/OUTPUT
  → NIK_NAT_OUT_TCP_V4 或 NIK_NAT_OUT_TCP_V6
  → REDIRECT → Mihomo

Router UDP
  → mangle/OUTPUT
  → NIK_MGL_OUT_MARK_V4 或 NIK_MGL_OUT_MARK_V6
  → fwmark + 对应地址族的 policy route + lo
  → mangle/PREROUTING
  → NIK_MGL_PRE_TPROXY_V4 或 NIK_MGL_PRE_TPROXY_V6
  → Mihomo
```

正式链名：

```text
NIK_NAT_PRE_DNS_V4
NIK_NAT_PRE_TCP_V4
NIK_NAT_OUT_DNS_V4
NIK_NAT_OUT_TCP_V4
NIK_MGL_PRE_CTRL_V4
NIK_MGL_PRE_TPROXY_V4
NIK_MGL_OUT_MARK_V4

NIK_NAT_PRE_DNS_V6
NIK_NAT_PRE_TCP_V6
NIK_NAT_OUT_DNS_V6
NIK_NAT_OUT_TCP_V6
NIK_MGL_PRE_CTRL_V6
NIK_MGL_PRE_TPROXY_V6
NIK_MGL_OUT_MARK_V6
```

## 无 ucode 架构

### Mihomo 配置

```text
/etc/config/nikki
  → /etc/nikki/scripts/mixin.sh
  → jshn 生成 JSON
  → yq 结构化合并
  → /etc/nikki/run/config.yaml
```

### 防火墙

```text
/etc/nikki/scripts/firewall_fw3.sh
  → ipset restore（family inet / inet6）
  → iptables-restore --noflush
  → ip6tables-restore --noflush
  → ip -4 / ip -6 rule + route
```

### LuCI

普通配置继续使用 LuCI 的 UCI、文件和 rc 接口。原先 `luci.nikki` rpcd-ucode 对象的特殊操作改由固定程序处理：

```text
/usr/libexec/nikki-rpc
```

该程序只接受预定义子命令和白名单路径，不开放任意 shell 命令。

## 依赖

核心包依赖大致包括：

```text
firewall
iptables
ip6tables
ip6tables-mod-nat
ipset
ip-full
iptables-mod-tproxy
iptables-mod-extra
iptables-mod-ipopt
kmod-ipt-ipset
kmod-tun
ca-bundle
curl
yq
mihomo-meta 或 mihomo-alpha
```

OpenWrt 21.02 的 `iptables-mod-tproxy` 同时提供 xtables TPROXY 用户态扩展和对应内核模块；IPv6 `REDIRECT` 另需 `ip6tables-mod-nat`。

`mihomo-meta` 和 `mihomo-alpha` 使用现代 Go 工具链。纯官方 21.02 构建树通常需要回移较新的 `golang` feed，或改用与你架构匹配的预编译 Mihomo 包。

## 接入 OpenWrt 源码树

在本仓库目录运行：

```sh
./feed.sh /path/to/openwrt
```

脚本会在目标源码树的 `package/feeds/nikki-legacy` 下分别创建四个软件包符号链接。之后执行：

```sh
cd /path/to/openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig
```

选择：

```text
Network → nikki
LuCI → Applications → luci-app-nikki
Network → mihomo-meta
```

并确认目标固件已启用 IPv6 及上述 xtables 依赖。

## 本地安装 IPK

把编译得到的依赖包、Mihomo、Nikki 和 LuCI IPK 放在同一目录，然后在路由器上执行：

```sh
./install.sh
```

该脚本只安装本地 IPK，不连接上游 Nikki 的 firewall4 软件源。

## 调试

```sh
/etc/nikki/scripts/firewall_fw3.sh check
/etc/nikki/scripts/firewall_fw3.sh render
/etc/init.d/nikki restart

iptables-save | grep NIK_
ip6tables-save | grep NIK_

ip -4 rule show
ip -4 route show table 80
ip -6 rule show
ip -6 route show table 80

ipset list nik_reserved_v4
ipset list nik_reserved_v6
/etc/nikki/scripts/debug.sh > /tmp/nikki-debug.txt
```

## 状态说明

- 已通过仓库自带的 `./tests/run-tests.sh`：Shell/JavaScript/JSON 静态检查、模拟 UCI/ubus 的配置生成，以及 IPv4/IPv6 xtables 规则渲染测试；
- 已加入 IPv6 ACL 选择器隔离测试，避免仅配置 IPv4 地址时意外匹配全部 IPv6 流量，反之亦然；
- 未保留上游 `.github` 工作流，因为它们针对现代 OpenWrt 分支和上游发布流程，不适用于本 legacy 分支；
- 尚未在真实 OpenWrt 21.02 SDK 中完成完整编译，也未在实体路由器上执行双栈流量回归测试。

建议先在可串口救援或可刷机恢复的设备上测试。
