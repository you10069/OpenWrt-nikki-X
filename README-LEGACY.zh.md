# Nikki Legacy：OpenWrt 21.02 / firewall3 / xtables

这是基于 [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 改造的实验性 legacy 分支，目标是在 **OpenWrt 21.02 类系统、firewall3、iptables 和 ip6tables** 环境中运行，同时移除运行时 `ucode`、`firewall4` 和 nftables 依赖。

## Legacy v3 范围

已实现：

- IPv4 LAN 客户端及路由器本机 TCP `REDIRECT`；
- IPv4 LAN UDP `TPROXY`；
- IPv4 路由器本机 UDP：`OUTPUT MARK → IPv4 policy route → lo → PREROUTING TPROXY`；
- IPv4 LAN 与路由器本机 DNS `REDIRECT`；
- IPv6 LAN 与路由器本机 TCP、UDP 全部使用 `TPROXY`；
- IPv6 TCP/UDP 53 端口通过 Mihomo TPROXY 监听器劫持；
- IPv6 不创建 nat 表规则，不使用 `REDIRECT`，也不创建任何 `NIK_NAT_*_V6` 链；
- 按 OpenWrt 网络接口、IPv4、IPv6、MAC、路由器用户和用户组进行访问控制；
- IPv4/IPv6 保留地址、中国大陆地址、DSCP 和 fwmark 绕过；
- Mihomo `routing-mark` 防回环；
- firewall3 script include，在防火墙重载后恢复规则；
- 无 ucode 的 Mihomo 配置生成；
- 无 rpcd-ucode 的 LuCI 辅助后端。

IPv6 代理和 IPv6 DNS 劫持默认关闭。启用任意一项都必须存在 Mihomo `tproxy-port` 或 TPROXY listener。IPv4 DNS 劫持仍然使用普通 DNS listener。

暂未实现：

- TUN 数据面；
- cgroup 访问控制；
- 多 WAN、策略出口和复杂硬件加速兼容；
- 正式发布级别的实体设备回归测试。

## 数据路径

### IPv4 TCP

```text
LAN TCP
  → nat/PREROUTING
  → NIK_NAT_PRE_TCP_V4
  → REDIRECT → Mihomo redir-port

Router TCP
  → nat/OUTPUT
  → NIK_NAT_OUT_TCP_V4
  → REDIRECT → Mihomo redir-port
```

### IPv4 UDP

```text
LAN UDP
  → mangle/PREROUTING
  → NIK_MGL_PRE_CTRL_V4
  → NIK_MGL_PRE_TPROXY_V4
  → Mihomo tproxy-port

Router UDP
  → mangle/OUTPUT
  → NIK_MGL_OUT_MARK_V4
  → fwmark + IPv4 policy route + lo
  → mangle/PREROUTING
  → NIK_MGL_PRE_TPROXY_V4
```

### IPv6 TCP、UDP及DNS

```text
LAN IPv6 TCP/UDP/53
  → mangle/PREROUTING
  → NIK_MGL_PRE_CTRL_V6
  → NIK_MGL_PRE_TPROXY_V6
  → Mihomo tproxy-port

Router IPv6 TCP/UDP/53
  → mangle/OUTPUT
  → NIK_MGL_OUT_MARK_V6
  → fwmark + IPv6 policy route + lo
  → mangle/PREROUTING
  → NIK_MGL_PRE_TPROXY_V6
```

IPv6 规则文件中只有：

```text
*mangle
```

不会出现：

```text
*nat
REDIRECT
NIK_NAT_*_V6
```

## 正式链名

```text
IPv4 nat：
NIK_NAT_PRE_DNS_V4
NIK_NAT_PRE_TCP_V4
NIK_NAT_OUT_DNS_V4
NIK_NAT_OUT_TCP_V4

IPv4 mangle：
NIK_MGL_PRE_CTRL_V4
NIK_MGL_PRE_TPROXY_V4
NIK_MGL_OUT_MARK_V4

IPv6 mangle：
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
  → ip6tables-restore --noflush（仅 mangle）
  → ip -4 / ip -6 rule + route
```

### LuCI

普通配置继续使用 LuCI 的 UCI、文件和 rc 接口；原 `luci.nikki` rpcd-ucode 对象的特殊操作由固定程序处理：

```text
/usr/libexec/nikki-rpc
```

## 依赖

核心包依赖大致包括：

```text
firewall
iptables
ip6tables
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

本版不依赖：

```text
ip6tables-mod-nat
```

`mihomo-meta` 和 `mihomo-alpha` 使用现代 Go 工具链。纯官方 21.02 构建树通常需要回移较新的 `golang` feed，或改用与你架构匹配的预编译 Mihomo 包。

## 接入 OpenWrt 源码树

```sh
./feed.sh /path/to/openwrt
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

检查 IPv6 规则时，应确认没有输出：

```text
NIK_NAT_
-j REDIRECT
```

## 状态说明

- 已通过仓库自带的 `./tests/run-tests.sh`；
- 测试覆盖 Shell/JavaScript/JSON 静态检查、模拟 UCI/ubus 配置生成、IPv4/IPv6 规则渲染和 restore 调用；
- IPv6 测试明确检查规则文件不含 nat、REDIRECT 和 `NIK_NAT_*_V6`；
- 尚未在真实 OpenWrt 21.02 SDK 中完成完整编译，也未在实体双栈路由器上执行流量回归测试。

建议先在具备串口救援或可方便恢复固件的设备上测试。
