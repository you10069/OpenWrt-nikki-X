# Nikki Legacy v5：OpenWrt 21.02 / firewall3 / xtables

这是基于 [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 改造的实验性 legacy 分支，目标是在 **OpenWrt 21.02 类系统、firewall3、iptables 和 ip6tables** 环境中运行，同时移除运行时 `ucode`、`firewall4` 和 nftables 依赖。

**Legacy v5 完整保留 v4 的透明代理数据面，只新增 Mihomo 内核管理与更新能力，不重做 v4 的防火墙规则。**

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

## V5 Mihomo 内核更新

### 两个固定槽位

Nikki 软件包不再强制依赖虚拟包 `mihomo`。服务固定运行受管理的当前槽位：

```text
当前运行：/usr/libexec/nikki/mihomo
上一版本：/usr/libexec/nikki/mihomo.prev
```

首次启动时，如果当前槽位为空，但系统中存在旧软件包提供的 `/usr/libexec/mihomo` 或 `/usr/bin/mihomo`，会先复制到当前槽位，便于从旧安装平滑迁移。

只保留当前和上一版本，不建立无限历史版本目录。

### 四种更新源

1. **MetaCubeX 官方 Releases**：查询官方最新 Release，并选择适配本机架构的资产。
2. **ShellCrash 源**：可选择 HTTPS 自动回退、Cloudflare jsDelivr、标准 jsDelivr、GitHub Raw、作者 HTTPS 源、旧设备 HTTP 内测源，或自定义兼容仓库。
3. **自定义 Releases 地址 + Tag**：填写 Releases 根地址；Tag 默认 `latest`，也可填写 `v1.19.16` 等任意指定版本。
4. **精确直链**：完整 URL 原样下载，不自动拼接、改写路径或替换参数。

ShellCrash 自动模式只轮询四个 HTTPS 源。旧设备 HTTP 内测源仅作为手动选项提供，不会进入自动回退。

ShellCrash 兼容仓库首先尝试：

```text
<仓库根地址>/bin/meta/mihomo-linux-<架构>.<压缩格式>
<仓库根地址>/bin/meta/clash-linux-<架构>.<压缩格式>
```

之后才尝试兼容回退目录。

### 文件名与架构匹配顺序

文件名前缀固定优先：

```text
mihomo-linux-
clash-linux-
```

架构从具体到通用查找。例如设备的软件包架构为 `aarch64_cortex-a53` 时：

```text
aarch64_cortex-a53
→ aarch64-cortex-a53
→ aarch64
→ arm64
```

同时参考软件包管理器架构和 `uname -m`，避免只依赖一个粗粒度架构名称。

### 更新、回退与安全策略

- 不比较版本新旧：升级、降级、同版本覆盖均可执行；
- 下载完成后先识别 raw、`.gz`、`.tar.gz` 或 `.tgz`；tar 包只流式读取被选中的核心成员，不整体解包；
- 安装前校验文件大小、可执行权限及 `mihomo -v` 输出；
- 更新前检查临时目录和内核目录空间；
- 空间不足直接返回“空间不足，自行释放空间后重试”，不覆盖任一槽位；
- 更新时先把当前核心复制为上一版本，再启用已验证的新核心；
- 如果 Nikki 原本正在运行，而新核心导致服务重启失败，会恢复更新前的当前槽位和上一版本槽位，并尝试恢复服务；
- “回退”交换当前与上一槽位，因此回退后仍可再次切回；
- “删除上一版本”只删除 `mihomo.prev`，不影响当前核心；
- sysupgrade 保留两个槽位和 `/etc/nikki/core-update.state`。

LuCI 状态页显示：

```text
设备架构
当前运行版本
上一版本（回退 / 删除）
最新或目标版本
更新源
实际匹配文件和下载地址
更新状态与错误信息
```

空间充足时点击“更新内核”直接执行，不弹确认框。

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
/etc/nikki/scripts/core_update.sh rollback
/etc/nikki/scripts/core_update.sh delete-previous

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
- 覆盖精确直链不拼接、ShellCrash 兼容目录、具体到通用架构顺序；
- 覆盖更新、上一版本保留、回退、删除以及重启失败恢复；
- 尚未在真实 OpenWrt 21.02 SDK 中完成完整编译，也未在实体路由器上执行真实流量回归测试。

建议先在具备串口救援或容易恢复固件的设备上测试。
