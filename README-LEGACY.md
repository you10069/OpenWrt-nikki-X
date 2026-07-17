# Nikki Legacy: OpenWrt 21.02 / firewall3 / iptables

This is an experimental legacy fork of [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki). It targets OpenWrt 21.02-class systems using firewall3 and iptables, with no runtime dependency on ucode, firewall4 or nftables.

## Initial scope

Implemented:

- IPv4 transparent proxying;
- LAN and router TCP REDIRECT;
- LAN UDP TPROXY;
- router UDP via OUTPUT mark, policy routing and PREROUTING TPROXY;
- LAN/router DNS hijacking;
- access control by OpenWrt network, IPv4, MAC, local user and local group;
- reserved/China IPv4, DSCP and fwmark bypasses;
- Mihomo routing-mark loop prevention;
- firewall3 script include reload integration;
- Shell+jshn+yq config generation;
- a fixed `/usr/libexec/nikki-rpc` helper instead of rpcd-ucode.

Not implemented yet: IPv6 transparent proxying, TCP TPROXY, TUN data plane, cgroup ACLs, advanced multi-WAN handling and full hardware regression coverage.

## Chain names

```text
NIK_NAT_PRE_DNS_V4
NIK_NAT_PRE_TCP_V4
NIK_NAT_OUT_DNS_V4
NIK_NAT_OUT_TCP_V4
NIK_MGL_PRE_CTRL_V4
NIK_MGL_PRE_TPROXY_V4
NIK_MGL_OUT_MARK_V4
```

## Buildroot integration

```sh
./feed.sh /path/to/openwrt
cd /path/to/openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig
```

Select `nikki`, `luci-app-nikki` and one Mihomo variant. A modern Go feed or a compatible prebuilt Mihomo package may be required on a stock 21.02 buildroot.

See [README.zh.md](README.zh.md) for architecture, dependencies, installation and debugging details.

## Validation status

The included `./tests/run-tests.sh` passes shell/JavaScript/JSON static checks, simulated UCI/ubus mixin generation, and rendered iptables rule tests. The upstream GitHub Actions workflows are intentionally omitted because they target modern OpenWrt branches and upstream publishing. This source has not yet completed a full build in a real OpenWrt 21.02 SDK or hardware traffic regression testing.
