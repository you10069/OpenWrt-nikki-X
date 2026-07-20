# Nikki Legacy v6: OpenWrt 21.02 / firewall3 / xtables

This is an experimental legacy fork of [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki). It targets OpenWrt 21.02-class systems using firewall3, iptables and ip6tables, without runtime dependencies on ucode, firewall4 or nftables.

Legacy v6 preserves the transparent-proxy data plane and rebuilds the Mihomo updater around one managed core, fixed storage thresholds and a background update task.

## Transparent-proxy mode matrix

| Traffic | Supported modes |
|---|---|
| IPv4 TCP | Disable / REDIRECT / TPROXY / TUN |
| IPv4 UDP | Disable / TPROXY / TUN |
| IPv6 TCP | Disable / REDIRECT / TPROXY / TUN |
| IPv6 UDP | Disable / TPROXY / TUN |
| IPv4 DNS TCP/UDP 53 | Disable / REDIRECT to Mihomo `dns.listen` / TPROXY to Mihomo `tproxy-port` / TUN |
| IPv6 DNS TCP/UDP 53 | Disable / REDIRECT to Mihomo `dns.listen` / TPROXY to Mihomo `tproxy-port` / TUN |

IPv6 TCP and DNS REDIRECT use the ip6tables nat table and require `ip6tables-mod-nat`. The default Mihomo DNS listener is dual-stack: `[::]:1053`.

Implemented data-plane features:

- independent IPv4/IPv6 TCP and UDP mode selection;
- IPv4 TCP REDIRECT and TCP/UDP TPROXY;
- IPv6 TCP REDIRECT and TCP/UDP TPROXY;
- IPv4 DNS REDIRECT to the Mihomo DNS listener, interception through the Mihomo TPROXY listener, or routing through TUN;
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

## V6 single-core updater

Nikki uses one active path:

```text
/usr/libexec/nikki/mihomo
```

There is no persistent previous slot, manual rollback, or automatic rollback. Once the fixed space conditions are satisfied, a requested update replaces the active core. The installed file is then checked for ELF architecture compatibility, made executable, run with `mihomo -v`, and required to yield a version. Any failure removes the candidate and leaves Nikki without a managed core.

A firmware-provided `/usr/libexec/mihomo` or `/usr/bin/mihomo` is exposed through a symlink instead of being copied into overlay, so it consumes no writable core storage.

Sources:

1. **MetaCubeX official latest release** — GitHub API direct for up to 10 seconds, then the API through `gh-proxy.com`. OpenWrt targets map directly to generic Go release architectures. Automatic asset probing tries PROXY, PROXYNET, and GitHub Direct in order, with 5 seconds per URL and stops at the first success.
2. **ShellCrash sources** — uses only `bin/version` and `bin/meta/clash-linux-<arch>.tar.gz`. Automatic mode tries JSdelivr CF, jsDelivr CDN, the HTTPS mirror, and GitHub Direct in order, stopping at the first successful 5-second probe.
3. **Custom Releases URL + tag** — uses the mapped generic architecture filename.
4. **Exact direct URL** — probes and downloads the configured URL verbatim.

Storage policy is fixed in the backend. With no current core, at least 50 MiB of writable storage is required; 70 MiB selects disk download, while 50–70 MiB requires more than 25 MiB available in `/tmp`/memory. With a current core, the operation is allowed when either writable storage or memory has at least 20 MiB; disk download is selected at 30 MiB or above, otherwise `/tmp` is used when memory permits. Available memory is the smaller of `MemAvailable` and `/tmp` free space. Background updates have a hard five-minute limit.

LuCI requires source changes to be committed with **Save & Apply**. Check/update operations do not overwrite the source display or show transient notifications. A source fingerprint clears the checked version and reports that the source has changed. The force-delete action confirms before deleting a downloaded core, reports the released MiB, and explains that a firmware symlink does not occupy writable space.

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
NIK_NAT_PRE_TCP_V6
NIK_NAT_OUT_DNS_V6
NIK_NAT_OUT_TCP_V6

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
or TCP/UDP 53 -> mangle TPROXY -> Mihomo tproxy-port
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
/etc/nikki/scripts/core_update.sh start-update
/etc/nikki/scripts/core_update.sh delete-current
```

## Validation status

`./tests/run-tests.sh` covers shell/JavaScript/JSON static checks, simulated UCI/ubus mixin generation, independent mode combinations, IPv4/IPv6 rule rendering, IPv6 TCP REDIRECT, IPv4 DNS TPROXY, TUN chains and restore calls. DNS-only TPROXY/TUN tests verify that no unintended NAT/REDIRECT rules are generated. Core-updater simulations cover official API fallback and first-success probing, exact direct URLs, fixed ShellCrash paths, generic architecture mapping, single-core replacement, post-install validation, delete-on-failure, current-core deletion and service-start failure handling.

This source has not yet completed a full build in a real OpenWrt 21.02 SDK or physical-router traffic regression testing.

See [README.zh.md](README.zh.md) for Chinese documentation.
