# Nikki Legacy: OpenWrt 21.02 / firewall3 / xtables

This is an experimental legacy fork of [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki). It targets OpenWrt 21.02-class systems using firewall3, iptables and ip6tables, with no runtime dependency on ucode, firewall4 or nftables.

## Legacy v3 scope

Implemented:

- IPv4 LAN/router TCP REDIRECT;
- IPv4 LAN UDP TPROXY and router UDP OUTPUT-mark policy routing;
- IPv4 LAN/router DNS REDIRECT;
- IPv6 LAN/router TCP and UDP TPROXY;
- IPv6 LAN/router port-53 interception through the TPROXY listener;
- no IPv6 NAT table, REDIRECT target or `NIK_NAT_*_V6` chains;
- access control by OpenWrt network, IPv4, IPv6, MAC, local user and local group;
- reserved/China IPv4 and IPv6, DSCP and fwmark bypasses;
- Mihomo routing-mark loop prevention;
- firewall3 script-include reload integration;
- Shell+jshn+yq config generation;
- a fixed `/usr/libexec/nikki-rpc` helper instead of rpcd-ucode.

IPv6 proxying and IPv6 DNS interception remain disabled by default. Enabling either requires a Mihomo TPROXY port/listener. IPv4 DNS interception still requires Mihomo's ordinary DNS listener.

Not implemented yet: TUN data plane, cgroup ACLs, advanced multi-WAN handling and full hardware regression coverage.

## Chain names

```text
IPv4 nat:
NIK_NAT_PRE_DNS_V4
NIK_NAT_PRE_TCP_V4
NIK_NAT_OUT_DNS_V4
NIK_NAT_OUT_TCP_V4

IPv4 mangle:
NIK_MGL_PRE_CTRL_V4
NIK_MGL_PRE_TPROXY_V4
NIK_MGL_OUT_MARK_V4

IPv6 mangle only:
NIK_MGL_PRE_CTRL_V6
NIK_MGL_PRE_TPROXY_V6
NIK_MGL_OUT_MARK_V6
```

## Data paths

```text
IPv4 LAN TCP:
nat/PREROUTING -> NIK_NAT_PRE_TCP_V4 -> REDIRECT -> Mihomo redir-port

IPv4 router TCP:
nat/OUTPUT -> NIK_NAT_OUT_TCP_V4 -> REDIRECT -> Mihomo redir-port

IPv4 LAN UDP:
mangle/PREROUTING -> NIK_MGL_PRE_CTRL_V4 -> NIK_MGL_PRE_TPROXY_V4

IPv4 router UDP:
mangle/OUTPUT mark -> IPv4 policy route -> lo -> PREROUTING TPROXY

IPv6 LAN TCP/UDP/DNS:
mangle/PREROUTING -> NIK_MGL_PRE_CTRL_V6 -> NIK_MGL_PRE_TPROXY_V6

IPv6 router TCP/UDP/DNS:
mangle/OUTPUT mark -> IPv6 policy route -> lo -> PREROUTING TPROXY
```

## Buildroot integration

```sh
./feed.sh /path/to/openwrt
cd /path/to/openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig
```

Select `nikki`, `luci-app-nikki` and one Mihomo variant. Ensure IPv6, `ip6tables`, `iptables-mod-tproxy` and the listed xtables dependencies are enabled. No `ip6tables-mod-nat` dependency is used. A modern Go feed or a compatible prebuilt Mihomo package may be required on a stock 21.02 buildroot.

See [README.zh.md](README.zh.md) for architecture, dependencies, installation and debugging details.

## Validation status

The included `./tests/run-tests.sh` passes shell/JavaScript/JSON static checks, simulated UCI/ubus mixin generation, and rendered IPv4/IPv6 xtables rule tests. The IPv6 regression test explicitly rejects `*nat`, `REDIRECT` and `NIK_NAT_*_V6` output. This source has not yet completed a full build in a real OpenWrt 21.02 SDK or dual-stack hardware traffic regression testing.
