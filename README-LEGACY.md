# Nikki Legacy: OpenWrt 21.02 / firewall3 / xtables

This is an experimental legacy fork of [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki). It targets OpenWrt 21.02-class systems using firewall3, iptables and ip6tables, without runtime dependencies on ucode, firewall4 or nftables.

## Legacy v4 scope

The transparent proxy mode is selected independently by address family and protocol:

| Traffic | Supported modes |
|---|---|
| IPv4 TCP | Disable / REDIRECT / TPROXY / TUN |
| IPv4 UDP | Disable / TPROXY / TUN |
| IPv6 TCP | Disable / TPROXY / TUN |
| IPv6 UDP | Disable / TPROXY / TUN |
| IPv4 DNS TCP/UDP 53 | Disable / REDIRECT to Mihomo `dns.listen` |
| IPv6 DNS TCP/UDP 53 | Disable / TPROXY to Mihomo `tproxy-port` as ordinary transparent traffic |

IPv6 does not access the ip6tables nat table and does not require `ip6tables-mod-nat`.

Implemented:

- independent IPv4/IPv6 TCP and UDP mode selection;
- IPv4 TCP REDIRECT and TCP/UDP TPROXY;
- IPv6 TCP/UDP TPROXY;
- IPv4 DNS REDIRECT to the Mihomo DNS listener;
- IPv6 DNS interception through the Mihomo TPROXY listener;
- IPv4/IPv6 TUN routing using a dedicated fwmark and policy-routing table;
- TUN INPUT and FORWARD acceptance chains for both families;
- LAN and router-originated traffic handling;
- ACLs by OpenWrt network, IPv4, IPv6, MAC, local user and local group;
- reserved/China IPv4 and IPv6, DSCP and fwmark bypasses;
- Mihomo `routing-mark` loop prevention;
- firewall3 script-include reload integration;
- Shell+jshn+yq configuration generation;
- `/usr/libexec/nikki-rpc` instead of rpcd-ucode.

Not implemented yet: cgroup ACLs, advanced multi-WAN policy integration, ICMP TUN forwarding and full hardware regression coverage.

## Chain names

```text
IPv4 nat:
NIK_NAT_PRE_DNS_V4
NIK_NAT_PRE_TCP_V4
NIK_NAT_OUT_DNS_V4
NIK_NAT_OUT_TCP_V4

IPv4 mangle/filter:
NIK_MGL_PRE_CTRL_V4
NIK_MGL_PRE_TPROXY_V4
NIK_MGL_PRE_TUN_V4
NIK_MGL_OUT_MARK_V4
NIK_MGL_OUT_TUN_V4
NIK_FLT_IN_TUN_V4
NIK_FLT_FWD_TUN_V4

IPv6 mangle/filter only:
NIK_MGL_PRE_CTRL_V6
NIK_MGL_PRE_TPROXY_V6
NIK_MGL_PRE_TUN_V6
NIK_MGL_OUT_MARK_V6
NIK_MGL_OUT_TUN_V6
NIK_FLT_IN_TUN_V6
NIK_FLT_FWD_TUN_V6
```

## Data paths

```text
IPv4 DNS:
TCP/UDP 53 -> nat REDIRECT -> Mihomo dns.listen

IPv6 DNS:
TCP/UDP 53 -> mangle TPROXY -> Mihomo tproxy-port

TPROXY LAN:
PREROUTING -> NIK_MGL_PRE_CTRL_Vx -> NIK_MGL_PRE_TPROXY_Vx

TPROXY router:
OUTPUT mark -> TPROXY policy route -> lo -> PREROUTING TPROXY

TUN LAN:
PREROUTING -> NIK_MGL_PRE_CTRL_Vx -> NIK_MGL_PRE_TUN_Vx
             -> TUN mark -> dedicated route table -> Mihomo TUN device

TUN router:
OUTPUT -> NIK_MGL_OUT_TUN_Vx -> TUN mark
       -> dedicated route table -> Mihomo TUN device
```

When any protocol selects TUN, Nikki enables the generated Mihomo TUN configuration, disables Mihomo automatic routing/redirect, waits for the TUN device, and installs explicit IPv4/IPv6 fwmark routes. The current legacy backend intentionally forwards TCP and UDP only; `disable-icmp-forwarding` is enabled.

## Buildroot integration

```sh
./feed.sh /path/to/openwrt
cd /path/to/openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig
```

Select `nikki`, `luci-app-nikki` and one Mihomo variant. A modern Go feed or a compatible prebuilt Mihomo package may be required on a stock 21.02 buildroot.

## Validation status

`./tests/run-tests.sh` covers shell/JavaScript/JSON static checks, simulated UCI/ubus mixin generation, independent mode combinations, IPv4/IPv6 rule rendering, TUN chains and restore calls. Tests reject every IPv6 nat/REDIRECT rule.

This source has not yet completed a full build in a real OpenWrt 21.02 SDK or physical-router traffic regression testing.

See [README.zh.md](README.zh.md) for Chinese documentation.
