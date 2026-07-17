# Nikki Legacy: OpenWrt 21.02 / firewall3 / xtables

This is an experimental legacy fork of [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki). It targets OpenWrt 21.02-class systems using firewall3, iptables and ip6tables, with no runtime dependency on ucode, firewall4 or nftables.

## Legacy v2 scope

Implemented:

- IPv4 and IPv6 transparent proxying;
- LAN and router TCP REDIRECT;
- LAN UDP TPROXY;
- router UDP via OUTPUT mark, per-family policy routing and PREROUTING TPROXY;
- IPv4/IPv6 LAN and router DNS hijacking;
- access control by OpenWrt network, IPv4, IPv6, MAC, local user and local group;
- reserved/China IPv4 and IPv6, DSCP and fwmark bypasses;
- Mihomo routing-mark loop prevention;
- firewall3 script include reload integration;
- Shell+jshn+yq config generation;
- a fixed `/usr/libexec/nikki-rpc` helper instead of rpcd-ucode.

IPv6 proxying and DNS hijacking remain disabled by default. IPv6 DNS hijacking requires an IPv6-capable Mihomo DNS listener; the shipped default is `[::]:1053`.

Not implemented yet: TCP TPROXY, TUN data plane, cgroup ACLs, advanced multi-WAN handling and full hardware regression coverage.

## Chain names

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

## Buildroot integration

```sh
./feed.sh /path/to/openwrt
cd /path/to/openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig
```

Select `nikki`, `luci-app-nikki` and one Mihomo variant. Ensure IPv6, `ip6tables`, `ip6tables-mod-nat` and the listed xtables dependencies are enabled. A modern Go feed or a compatible prebuilt Mihomo package may be required on a stock 21.02 buildroot.

See [README.zh.md](README.zh.md) for architecture, dependencies, installation and debugging details.

## Validation status

The included `./tests/run-tests.sh` passes shell/JavaScript/JSON static checks, simulated UCI/ubus mixin generation, and rendered IPv4/IPv6 xtables rule tests. The upstream GitHub Actions workflows are intentionally omitted because they target modern OpenWrt branches and upstream publishing. This source has not yet completed a full build in a real OpenWrt 21.02 SDK or dual-stack hardware traffic regression testing.
