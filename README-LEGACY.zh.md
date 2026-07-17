# Nikki Legacy：OpenWrt 21.02 / firewall3 / xtables

这是基于 [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 改造的实验性 legacy 分支，目标是在 **OpenWrt 21.02 类系统、firewall3、iptables 和 ip6tables** 环境中运行，同时移除运行时 `ucode`、`firewall4` 和 nftables 依赖。

## Legacy v4 模式矩阵

各地址族、各协议独立选择模式：

| 流量 | 可选模式 |
|---|---|
| IPv4 TCP | 关闭 / REDIRECT / TPROXY / TUN |
| IPv4 UDP | 关闭 / TPROXY / TUN |
| IPv6 TCP | 关闭 / TPROXY / TUN |
| IPv6 UDP | 关闭 / TPROXY / TUN |
| IPv4 DNS TCP/UDP 53 | 关闭 / REDIRECT 至 Mihomo `dns.listen` |
| IPv6 DNS TCP/UDP 53 | 关闭 / TPROXY 至 Mihomo `tproxy-port`，作为普通透明代理流量 |

IPv6 不访问 `ip6tables nat` 表，也不依赖 `ip6tables-mod-nat`。

## 已实现

- IPv4/IPv6 TCP、UDP 模式独立配置；
- IPv4 TCP REDIRECT；
- IPv4 TCP/UDP TPROXY；
- IPv6 TCP/UDP TPROXY；
- IPv4 DNS TCP/UDP 53 REDIRECT 至 Mihomo 内置 DNS 监听端口；
- IPv6 DNS TCP/UDP 53 TPROXY 至 Mihomo 普通 TPROXY 监听端口；
- IPv4/IPv6 TUN 路由、专用 fwmark 和独立策略路由表；
- TUN 接口 INPUT/FORWARD 放行；
- LAN 流量和路由器本机流量；
- 按 OpenWrt 网络、IPv4、IPv6、MAC、本机用户和用户组进行访问控制；
- IPv4/IPv6 保留地址、中国大陆地址、DSCP 和 fwmark 绕过；
- Mihomo `routing-mark` 防回环；
- firewall3 script include，在防火墙重载后恢复规则；
- `Shell + jshn + yq` 配置生成；
- `/usr/libexec/nikki-rpc` 替代 rpcd-ucode。

暂未实现：cgroup ACL、多 WAN 深度集成、ICMP TUN 转发及正式发布级实体设备回归测试。

## DNS 路径

### IPv4 DNS

```text
客户端或路由器本机 TCP/UDP 53
  → iptables nat REDIRECT
  → Mihomo dns.listen（例如 1053）
  → Mihomo 内置 DNS 模块
```

IPv4 DNS 会使用 fake-ip、hosts、nameserver-policy 等 Mihomo DNS 配置。

### IPv6 DNS

```text
客户端或路由器本机 TCP/UDP 53
  → ip6tables mangle TPROXY
  → Mihomo tproxy-port
  → 作为普通透明代理连接继续访问原始 IPv6 DNS 服务器
```

IPv6 DNS 不是送入 Mihomo 内置 DNS listener；它是强制代理 DNS 连接。这样无需增加 IPv6 NAT 模块。

## TUN 转发

TUN 使用独立标记和路由表：

```text
TPROXY mark：0x80/0xFF，路由表 80
TUN mark：   0x81/0xFF，路由表 81
Core mark：  0x82/0xFF
```

### LAN 流量

```text
PREROUTING
  → NIK_MGL_PRE_CTRL_V4/V6
  → NIK_MGL_PRE_TUN_V4/V6
  → MARK 0x81
  → ip rule / route table 81
  → Mihomo TUN 设备
```

### 路由器本机流量

```text
OUTPUT
  → NIK_MGL_OUT_TUN_V4/V6
  → MARK 0x81
  → ip rule / route table 81
  → Mihomo TUN 设备
```

### TUN 接口放行

```text
NIK_FLT_IN_TUN_V4/V6
NIK_FLT_FWD_TUN_V4/V6
```

规则允许：

- 从 TUN 设备进入路由器本机；
- 从 TUN 设备转发出去；
- 转发到 TUN 设备。

当任意 TCP/UDP 模式选择 TUN 时，启动脚本会：

1. 启用生成配置中的 Mihomo TUN；
2. 关闭 Mihomo `auto-route`、`auto-redirect` 和 `auto-detect-interface`；
3. 等待 TUN 设备进入 UP 状态；
4. 安装 IPv4/IPv6 TUN 策略路由；
5. 加载 mangle 和 filter 规则；
6. 任一步失败时撤销已创建的路由与防火墙规则。

当前 legacy 后端只处理 TCP/UDP，因此设置 `disable-icmp-forwarding: true`。

## 正式链名

```text
IPv4 nat：
NIK_NAT_PRE_DNS_V4
NIK_NAT_PRE_TCP_V4
NIK_NAT_OUT_DNS_V4
NIK_NAT_OUT_TCP_V4

IPv4 mangle/filter：
NIK_MGL_PRE_CTRL_V4
NIK_MGL_PRE_TPROXY_V4
NIK_MGL_PRE_TUN_V4
NIK_MGL_OUT_MARK_V4
NIK_MGL_OUT_TUN_V4
NIK_FLT_IN_TUN_V4
NIK_FLT_FWD_TUN_V4

IPv6 mangle/filter：
NIK_MGL_PRE_CTRL_V6
NIK_MGL_PRE_TPROXY_V6
NIK_MGL_PRE_TUN_V6
NIK_MGL_OUT_MARK_V6
NIK_MGL_OUT_TUN_V6
NIK_FLT_IN_TUN_V6
NIK_FLT_FWD_TUN_V6
```

## 依赖

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

不依赖：

```text
ip6tables-mod-nat
ucode
rpcd-mod-ucode
firewall4
nftables
```

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
Network → mihomo-meta 或 mihomo-alpha
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
ip -4 route show table 81
ip -6 rule show
ip -6 route show table 80
ip -6 route show table 81

ip link show dev nikki
/etc/nikki/scripts/debug.sh > /tmp/nikki-debug.txt
```

检查 IPv6 规则时，不应出现：

```text
*nat
NIK_NAT_*_V6
-j REDIRECT
```

## 验证状态

- 已通过仓库自带的 `./tests/run-tests.sh`；
- 覆盖 Shell、JavaScript、JSON 静态检查；
- 覆盖模拟 UCI/ubus 配置生成；
- 覆盖 IPv4 TCP REDIRECT/TPROXY、IPv4/IPv6 TUN、IPv6 DNS-only TPROXY；
- 覆盖 TUN mangle/filter 链和 restore 调用；
- IPv6 测试会拒绝任何 nat/REDIRECT 规则；
- 尚未在真实 OpenWrt 21.02 SDK 中完成完整编译，也未在实体路由器上执行真实流量回归测试。

建议先在具备串口救援或容易恢复固件的设备上测试。
