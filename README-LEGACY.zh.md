# Nikki Legacy v6：OpenWrt 21.02 / firewall3 / xtables

这是基于 [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 改造的实验性 legacy 分支，目标是在 **OpenWrt 21.02 类系统、firewall3、iptables 和 ip6tables** 环境中运行，同时移除运行时 `ucode`、`firewall4` 和 nftables 依赖。

**Legacy v6 保留透明代理数据面，并将 Mihomo 更新器重构为单内核、固定空间策略和后台更新任务。**

## 透明代理模式矩阵

各地址族、各协议独立选择模式：

| 流量 | 可选模式 |
|---|---|
| IPv4 TCP | 关闭 / REDIRECT / TPROXY / TUN |
| IPv4 UDP | 关闭 / TPROXY / TUN |
| IPv6 TCP | 关闭 / REDIRECT / TPROXY / TUN |
| IPv6 UDP | 关闭 / TPROXY / TUN |
| IPv4 DNS TCP/UDP 53 | 关闭 / REDIRECT 至 Mihomo `dns.listen` / TPROXY 至 Mihomo `tproxy-port` / TUN |
| IPv6 DNS TCP/UDP 53 | 关闭 / REDIRECT 至 Mihomo `dns.listen` / TPROXY 至 Mihomo `tproxy-port` / TUN |

IPv6 TCP 和 DNS REDIRECT 使用 `ip6tables nat` 表，并依赖 `ip6tables-mod-nat`。默认 Mihomo DNS 监听地址为双栈 `[::]:1053`。

## 已实现的数据面功能

- IPv4/IPv6 TCP、UDP 模式独立配置；
- IPv4 TCP REDIRECT；
- IPv4 TCP/UDP TPROXY；
- IPv6 TCP REDIRECT、TCP/UDP TPROXY；
- IPv4 DNS TCP/UDP 53 REDIRECT 至 Mihomo 内置 DNS 监听端口、TPROXY 至 Mihomo 普通 TPROXY 监听端口，或通过 TUN 路由；
- IPv6 DNS TCP/UDP 53 REDIRECT 至 Mihomo 内置 DNS 监听端口、TPROXY 至 Mihomo 普通 TPROXY 监听端口，或通过 TUN 路由；
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

## V6 内核更新

### 单一活动内核

Nikki 固定使用：

```text
/usr/libexec/nikki/mihomo
```

更新器不再建立 `mihomo.prev`，也不提供上一版本、手动回退或自动回滚。用户发起更新并满足固定空间条件后，旧内核不再作为保护对象；新文件直接替换活动路径，随后执行 ELF 架构校验、`chmod 0755`、`mihomo -v` 和版本提取。任一验证失败都会删除新内核并进入无内核状态。

如果固件内置 `/usr/libexec/mihomo` 或 `/usr/bin/mihomo`，Nikki 会在活动路径为空时建立软链接，不复制大文件到 overlay。此类固件核心不占用可写空间。

### 更新源

1. **MetaCubeX 官方最新发布**：官方 API 直连最多等待 10 秒，失败后通过 `gh-proxy.com` 查询。设备架构直接映射到官方通用 Go 架构；自动下载按 PROXY、PROXYNET、GitHub 直链顺序探测，每个连接最多 5 秒，首个成功即停止。
2. **ShellCrash 源**：固定使用 `bin/version` 和 `bin/meta/clash-linux-<架构>.tar.gz`。自动模式按 JSdelivr CF、jsDelivr CDN、HTTPS 镜像、GitHub 直链顺序探测，每个连接最多 5 秒，首个成功即停止。
3. **自定义 Releases 地址 + Tag**：使用固定的通用架构文件名。
4. **精确直链**：完整 URL 原样探测和下载。

OpenWrt 的 `aarch64_cortex-a53`、`aarch64_cortex-a72` 等目标统一映射为 `arm64`；x86_64 使用 `amd64-compatible`。不再探测具体 CPU target、多前缀、多压缩后缀或历史目录组合。

### 固定空间策略

没有当前内核时：

- 硬盘小于 50 MiB：拒绝更新；
- 硬盘大于等于 70 MiB：下载到内核目录；
- 硬盘 50～70 MiB 且可用内存大于 25 MiB：下载到 `/tmp`；
- 其他情况：空间不足。

已有当前内核时：

- 硬盘和内存都小于 20 MiB：空间不足；
- 任意一个大于等于 20 MiB：允许更新；
- 硬盘大于等于 30 MiB：下载到内核目录；
- 否则在内存满足 20 MiB 时下载到 `/tmp`；必要时先删除旧核心以释放空间。

可用内存取 `MemAvailable` 与 `/tmp` 可用空间中的较小值。后台更新任务最长运行 5 分钟。

### LuCI 交互

修改更新源后必须先点击页面底部的“保存并应用”。来源指纹变化后，页面显示“已切换更新源，未检查更新！”。检查或更新期间不弹出临时通知，按钮保持锁定，并通过状态轮询在完成后刷新页面。

“强行删除当前内核”用于释放下载核心占用的 overlay 空间。删除普通下载核心后显示实际释放的 MiB；固件内置软链接不会被视为可释放空间，并提示无法通过删除它获得更新空间。

## DNS 路径

### IPv4 DNS

```text
客户端或路由器本机 TCP/UDP 53
  → iptables nat REDIRECT
  → Mihomo dns.listen（例如 1053）
  → Mihomo 内置 DNS 模块
或：TCP/UDP 53
  → iptables mangle TPROXY
  → Mihomo tproxy-port
  → 作为普通透明代理连接继续访问原始 IPv4 DNS 服务器
或：TCP/UDP 53 → TUN mark → 专用路由表 → Mihomo TUN 设备
```

IPv4 DNS 使用 REDIRECT 时会进入 Mihomo 内置 DNS 模块；使用 TPROXY 或 TUN 时会保留原始 DNS 目标并作为透明代理连接处理。

### IPv6 DNS

```text
客户端或路由器本机 TCP/UDP 53
  → ip6tables nat REDIRECT
  → Mihomo dns.listen（必须监听 `[::]:端口`）
或：TCP/UDP 53
  → ip6tables mangle TPROXY
  → Mihomo tproxy-port
  → 作为普通透明代理连接继续访问原始 IPv6 DNS 服务器
或：TCP/UDP 53 → TUN mark → 专用路由表 → Mihomo TUN 设备
```

IPv6 DNS 使用 REDIRECT 时进入 Mihomo 内置 DNS listener；使用 TPROXY 或 TUN 时保留原始 DNS 目标并作为透明代理连接处理。

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
```

不再强制依赖：

```text
mihomo（虚拟包）
mihomo-meta
mihomo-alpha
```

其中 `mihomo-meta` 或 `mihomo-alpha` 仍可选装，用于编译期提供核心或迁移已有核心，但不是 Nikki 软件包的强制依赖。

额外依赖：

```text
ip6tables-mod-nat
```

不依赖：

```text
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

必须选择：

```text
Network → nikki
LuCI → Applications → luci-app-nikki
```

可选选择：

```text
Network → mihomo-meta 或 mihomo-alpha
```

也可以不编译 Mihomo 软件包，安装 Nikki 后再从 LuCI 下载受管理的核心。

## 调试

```sh
/etc/nikki/scripts/firewall_fw3.sh check
/etc/nikki/scripts/firewall_fw3.sh render
/etc/init.d/nikki restart

/etc/nikki/scripts/core_update.sh status
/etc/nikki/scripts/core_update.sh architectures
/etc/nikki/scripts/core_update.sh check
/etc/nikki/scripts/core_update.sh update
/etc/nikki/scripts/core_update.sh start-update
/etc/nikki/scripts/core_update.sh delete-current

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

选择 IPv6 DNS REDIRECT 时，应出现：

```text
*nat
NIK_NAT_PRE_DNS_V6
NIK_NAT_PRE_TCP_V6
NIK_NAT_OUT_DNS_V6
NIK_NAT_OUT_TCP_V6
-j REDIRECT --to-ports 1053
```

## 验证状态

- 已通过仓库自带的 `./tests/run-tests.sh`；
- 覆盖 Shell、JavaScript、JSON 静态检查；
- 覆盖模拟 UCI/ubus 配置生成；
- 覆盖 IPv4 TCP REDIRECT/TPROXY、IPv6 TCP REDIRECT、IPv4 DNS TPROXY、IPv4/IPv6 TUN、IPv4/IPv6 DNS-only TUN、IPv6 DNS-only REDIRECT/TPROXY；
- 覆盖 TUN mangle/filter 链和 restore 调用；
- IPv6 DNS REDIRECT 测试会验证 nat/REDIRECT 规则，DNS-only TPROXY/TUN 模式则不会生成非预期 NAT 规则；
- 覆盖官方 API 回退、官方顺序探测首个成功、精确直链和 ShellCrash 固定文件路径；
- 覆盖单内核强制替换、覆盖后验证、验证失败删除、当前内核删除和服务启动失败处理；
- 尚未在真实 OpenWrt 21.02 SDK 中完成完整编译，也未在实体路由器上执行真实流量回归测试。

建议先在具备串口救援或容易恢复固件的设备上测试。
