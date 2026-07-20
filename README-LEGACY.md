# Nikki Legacy v5: OpenWrt 21.02 / firewall3 / xtables

This is an experimental legacy fork of [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki). It targets OpenWrt 21.02-class systems using firewall3, iptables and ip6tables, without runtime dependencies on ucode, firewall4 or nftables.

Legacy v5 preserves the Legacy v4 transparent-proxy data plane and adds managed Mihomo core updates. It does not redesign the v4 firewall rules.

## Transparent-proxy mode matrix

| Traffic | Supported modes |
|---|---|
| IPv4 TCP | Disable / REDIRECT / TPROXY / TUN |
| IPv4 UDP | Disable / TPROXY / TUN |
| IPv6 TCP | Disable / TPROXY / TUN |
| IPv6 UDP | Disable / TPROXY / TUN |
| IPv4 DNS TCP/UDP 53 | Disable / REDIRECT to Mihomo `dns.listen` / TUN |
| IPv6 DNS TCP/UDP 53 | Disable / REDIRECT to Mihomo `dns.listen` / TPROXY to Mihomo `tproxy-port` / TUN |

IPv6 DNS REDIRECT uses the ip6tables nat table and requires `ip6tables-mod-nat`. The default Mihomo DNS listener is dual-stack: `[::]:1053`.

Implemented data-plane features:

- independent IPv4/IPv6 TCP and UDP mode selection;
- IPv4 TCP REDIRECT and TCP/UDP TPROXY;
- IPv6 TCP/UDP TPROXY;
- IPv4 DNS REDIRECT to the Mihomo DNS listener, or routing through TUN;
- IPv6 DNS REDIRECT to the Mihomo DNS listener, interception through the Mihomo TPROXY listener, or routing through TUN;
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

## V5 managed core updater

Nikki no longer requires a virtual `mihomo` package at package-install time. The service always runs the managed active slot:

```text
Active:   /usr/libexec/nikki/mihomo
Previous: /usr/libexec/nikki/mihomo.prev
```

On first start, a legacy executable at `/usr/libexec/mihomo` or `/usr/bin/mihomo` is copied into the active slot when the active slot is empty.

Available sources:

1. **Official MetaCubeX Releases** — queries the latest release and selects an architecture-compatible asset.
2. **ShellCrash sources** — choose automatic HTTPS fallback, Cloudflare jsDelivr, standard jsDelivr, GitHub Raw, the author's HTTPS mirror, the legacy HTTP beta source, or a custom compatible repository.
3. **Custom Releases URL + tag** — uses `latest` or an exact tag such as `v1.19.16`.
4. **Exact direct URL** — downloads the configured URL verbatim and never appends or rewrites its path.

Automatic ShellCrash mode tries only the four encrypted HTTPS sources. The legacy HTTP beta source is listed for old TLS-incompatible devices but must be selected manually.

Asset discovery prefers `mihomo-linux-*` before `clash-linux-*`. Architecture candidates are tried from the package-specific target toward generic aliases, for example:

```text
aarch64_cortex-a53
→ aarch64-cortex-a53
→ aarch64
→ arm64
```

Update safety:

- accepts upgrades, downgrades and same-version replacement;
- validates archive layout, streams only the selected tar member, and checks executable size plus `mihomo -v` output before installation;
- checks temporary and core-filesystem free space before replacing either slot;
- copies the current active core into the previous slot, then activates the validated candidate;
- restores both pre-update core slots when a running service cannot restart with the candidate;
- supports one-click rollback by swapping the two slots;
- supports deleting only the previous slot;
- preserves both slots and updater state through sysupgrade.

LuCI displays the detected architecture, current running version, previous version, checked/latest version, selected source, resolved asset/download URL and last operation status. Updates run directly after the button is pressed; insufficient storage returns an error without opening a confirmation dialog or replacing either slot.

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

IPv6 nat:
NIK_NAT_PRE_DNS_V6
NIK_NAT_OUT_DNS_V6

IPv6 mangle/filter:
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
or TCP/UDP 53 -> TUN mark -> dedicated route table -> Mihomo TUN device

IPv6 DNS:
TCP/UDP 53 -> nat REDIRECT -> Mihomo dns.listen
or TCP/UDP 53 -> mangle TPROXY -> Mihomo tproxy-port
or TCP/UDP 53 -> TUN mark -> dedicated route table -> Mihomo TUN device

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

Select `nikki` and `luci-app-nikki`. Selecting `mihomo-meta` or `mihomo-alpha` is optional: an installed legacy core can be migrated into the managed active slot, or the core can be downloaded later from LuCI.

A modern Go feed may still be needed if you choose to compile a Mihomo package on a stock 21.02 buildroot.

## Core updater CLI

```sh
/etc/nikki/scripts/core_update.sh status
/etc/nikki/scripts/core_update.sh architectures
/etc/nikki/scripts/core_update.sh check
/etc/nikki/scripts/core_update.sh update
/etc/nikki/scripts/core_update.sh rollback
/etc/nikki/scripts/core_update.sh delete-previous
```

## Validation status

`./tests/run-tests.sh` covers shell/JavaScript/JSON static checks, simulated UCI/ubus mixin generation, independent mode combinations, IPv4/IPv6 rule rendering, TUN chains and restore calls. Tests reject every IPv6 nat/REDIRECT rule. Core-updater simulations cover exact direct URLs, ShellCrash-compatible repository paths, architecture ordering, update/rollback/delete and restart-failure recovery.

This source has not yet completed a full build in a real OpenWrt 21.02 SDK or physical-router traffic regression testing.

See [README.zh.md](README.zh.md) for Chinese documentation.
