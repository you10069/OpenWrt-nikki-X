## 2026-07-20 · Official download channels and source labels (nikki r5 / luci r4)

- Added an official MetaCubeX download-source selector with automatic HTTPS fallback, PROXY acceleration, PROXYNET acceleration and GitHub direct-link modes.
- Unified official release metadata lookup: try the GitHub API directly for up to 10 seconds, then retry through `gh-proxy.com`.
- Made automatic official asset download try `gh-proxy.com`, `ghproxy.net` and the original GitHub Release URL in order.
- Reused one validated Release JSON response for both version detection and architecture asset matching.
- Renamed ShellCrash source labels to JSdelivr CF, jsDelivr CDN, GitHub direct link, HTTPS mirror and HTTP beta source without changing their underlying URLs or fallback order.
- Added updater simulations for every official download preset and API fallback behavior.
- Bumped the nikki package release to r5 and luci-app-nikki to r4.

## 2026-07-20 · IPv6 TCP REDIRECT and IPv4 DNS TPROXY (nikki r4)

- Added IPv6 TCP REDIRECT for LAN and router-originated traffic through ip6tables nat chains, using the existing Mihomo Redirect Port/Listener.
- Added IPv4 DNS TPROXY for TCP/UDP port 53, including LAN interception, router OUTPUT marking, loopback reinjection and IPv4 policy routing.
- Restored the original shared-mode migration semantics for IPv6 TCP/UDP and changed the new-install IPv6 TCP default to REDIRECT.
- Kept named Redirect Listener address handling unchanged; only listener presence and port are validated.
- Ensured router-only TPROXY still hooks PREROUTING for loopback reinjection when LAN proxying is disabled.
- Added focused firewall rendering and migration regression tests.
- Bumped the nikki package release to r4 and luci-app-nikki to r3.

## 2026-07-18 · Proxy page-level safety notice (r10)

- Moved the general safety warning from the proxy form section to the native LuCI page description under the main Proxy Config title.
- Kept the top navigation tabs and the lower Proxy Config / Router Proxy / LAN Proxy / Bypass / Misc tabs unchanged.
- Retained the two per-option experimental warnings for mainland China IPv4 and IPv6 bypass.

## 2026-07-18 · Proxy configuration safety notices (r9)

- Added a warning below the Proxy Config heading advising users to keep defaults unless they understand the settings.
- Marked both China mainland IPv4 and IPv6 bypass switches as experimental and not recommended.
- Kept the existing defaults and proxy behavior unchanged.

## 2026-07-18 · Default official Releases URL in custom mode (r8)

- Added `https://github.com/MetaCubeX/mihomo/releases` as the LuCI default for the Custom Releases URL field.
- Selecting the custom Releases mode now shows the official MetaCubeX Releases address when no address has been saved.
- Existing user-defined Releases addresses remain unchanged and are never overwritten.

## 2026-07-18 · LuCI DNS notice (r7)

- Removed the generic homepage description and wiki usage link.
- Added a lightweight, larger DNS configuration notice below the page title.
- The notice reminds users to disable OpenWrt DNS Redirect and client-side encrypted/secure DNS.

## 2026-07-18 — Dynamic firewall backend status (r6)

- Replaced the fixed Legacy Backend capability sentence on the proxy page with a read-only Current Firewall row.
- Detect active firewall4 through the canonical `table inet fw4` and active firewall3 through characteristic fw3 iptables chains.
- Report active fw3, active fw4, mixed rules, installed-but-stopped backends, or an unknown/stopped state without creating or changing firewall rules.
- Added LuCI translations and regression tests for the new RPC/frontend contract.

## 2026-07-18 — LuCI core update save compatibility fix (r5)

- Avoid calling `uci.apply()` when there are no pending UCI changes.
- Fix `RPC call to uci/apply failed with ubus code 5` on OpenWrt 21.02.
- Allow repeated **Check Update** and **Update Core** operations when configuration is already saved.

## 2026.07.18.legacy5.3-r4

- Renamed the official updater source to MetaCubeX Official Latest Version while retaining the Custom Releases URL option for pinned tags.
- Added a dedicated Save Changes button inside the Mihomo Core Update section, immediately above Update Status.
- Limited the new button to parsing, saving and applying only the core-update section instead of unrelated page settings.
- Made Check Update and Update Core automatically save and apply current updater fields before invoking the backend action.
- Added dirty/saved source notices so the Update Source row clearly distinguishes edited settings from the last completed check result.
- Bumped luci-app-nikki package release from r3 to r4.

## 2026.07.18.legacy5.3-r3

- Restored the compact top status table to app version, core version, core status and the four service/dashboard actions.
- Moved all Mihomo updater runtime information and actions to the bottom of the Mihomo Core Update section.
- Ordered the updater rows as device architecture, current/update versions, source, file, address, status, check, update, saved previous version, rollback and deletion.
- Renamed the resolved download URL field to Update Address and displayed long source/file/address/status values with safe wrapping.
- Bumped luci-app-nikki package release from r2 to r3.

# Nikki Legacy changelog

## 2026.07.17.legacy5.3

- Fixed LuCI `PermissionError` on OpenWrt 21.02 by forcing `/usr/libexec/nikki-rpc` to mode `0755` during package preparation and again through an installation-time fallback.
- Completed a field-by-field LuCI/UCI/RPC/runtime audit and added regression assertions for the corresponding interfaces.
- Fixed Proxy Server Nameserver Policy overwrite so the init path removes the original profile value before merging the replacement generated by LuCI.
- Reworked failed core-update recovery to restore both the active and pre-existing previous slots, not only the active core.
- Made scheduled cron installation idempotent by removing stale Nikki-owned entries before writing the current schedules.
- Rejected zero/invalid TUN polling intervals and bounded the LuCI inputs, preventing an infinite TUN readiness loop and checking once more at the timeout boundary.
- Synchronized legacy ShellCrash source migration with the LuCI preset field and restored the default 03:00 schedule when no legacy cron expression exists.
- Added stale core-update lock recovery, cleared stale resolved-source state, exposed the selected repository through RPC, and handled scheme-prefixed IPv6 wildcard controller addresses.
- Added the missing LuCI translation entries for helper errors and REDIRECT/TPROXY/TUN labels.
- Declared `jshn`, `jsonfilter` and `ubus` as explicit runtime dependencies instead of relying on indirect LuCI/base-system installation.
- Hardened core archive handling by rejecting unsafe member names and streaming only the selected executable instead of unpacking the whole archive.
- Made chunked editor writes transactional and atomic, with compatibility for older LuCI clients and safe UTF-16 chunk boundaries.
- Exposed the resolved asset name and concrete download URL in the LuCI status table.

## 2026.07.17.legacy5.2.1

- Restored the default Mihomo DNS listener to `[::]:1053`, because the default IPv4 DNS REDIRECT mode requires a stable destination port.
- Added migration fallback that sets `[::]:1053` only when `mixin.dns_listen` is absent; explicit custom listener values remain untouched.
- Kept all other Legacy v5.2 defaults unchanged.

## 2026.07.17.legacy5.2

- Enabled scheduled service restart by default while retaining the existing daily 03:00 cron expression.
- Changed the general IPv6 mixin default from explicit disable to unmodified.
- Kept TUN explicitly disabled by default and retained the existing device name and stack defaults.
- Kept DNS enabled but changed DNS IPv6, enhanced mode, listen address, Fake-IP range, Fake-IP cache and direct-nameserver follow-policy defaults to unmodified; overwrite checkboxes remain disabled.
- Changed the default proxy data plane to TPROXY for IPv4/IPv6 TCP and UDP, with IPv4 DNS REDIRECT and IPv6 DNS TPROXY.
- Left profile, external control, inbound, ACL, rule, GeoX, editor and log defaults unchanged.
- Applied the new values only when options are absent during migration; existing explicit user choices remain untouched.

## 2026.07.17.legacy5.1

- Added every ShellCrash core/script source currently published in `public/servers_chs.list` as a built-in selectable source.
- Added automatic HTTPS fallback across Cloudflare jsDelivr, standard jsDelivr, the author's HTTPS mirror and GitHub Raw.
- Kept the author's legacy HTTP beta source as an explicit manual option and excluded it from automatic fallback.
- Preserved custom ShellCrash-compatible repository support and backward compatibility with the legacy5 `repository_url` field.
- Recorded the concrete repository selected by automatic fallback in updater state and status output.
- Added regression coverage for HTTPS source fallback and HTTP exclusion.
- Reworked two-slot rollback to retain recoverable snapshots and atomically replace each slot, eliminating an intermittent rapid-swap failure found during repeated validation.

## 2026.07.17.legacy5

- Kept the Legacy v4 firewall3/iptables/TUN data plane unchanged and added a separate Mihomo core-management layer.
- Removed the mandatory dependency on the virtual `mihomo` package; Nikki now runs the managed core at `/usr/libexec/nikki/mihomo`.
- Added two fixed core slots: active `mihomo` and previous `mihomo.prev`, with update, rollback and previous-slot deletion actions.
- Added official MetaCubeX, ShellCrash-compatible repository, custom Releases URL + tag, and exact direct-URL update sources.
- Added specific-to-generic architecture fallback and `mihomo-linux-*` before `clash-linux-*` asset-name probing.
- Added download/extraction/executable validation, free-space checks and service-restart rollback protection.
- Added LuCI status fields for device architecture, current/previous/latest versions, selected source and last operation status.
- Added migration from legacy package-provided core paths and sysupgrade preservation for both managed slots.
- Added simulated regressions for direct URLs, ShellCrash repository layout, update, rollback, deletion and failed-restart recovery.

## 2026.04.08.legacy4

- Split transparent proxy settings into independent IPv4/IPv6 TCP, UDP and DNS modes.
- Added IPv4 TCP TPROXY while retaining REDIRECT and adding TUN selection.
- Kept IPv4 DNS REDIRECT targeted at Mihomo `dns.listen`.
- Defined IPv6 DNS as ordinary TCP/UDP 53 TPROXY traffic sent to Mihomo `tproxy-port`.
- Added explicit IPv4/IPv6 TUN mangle chains, router OUTPUT marking and a dedicated TUN fwmark/route table.
- Added IPv4/IPv6 filter chains that accept traffic entering from or forwarding through the Mihomo TUN device.
- Disabled Mihomo automatic TUN routing/redirect and installed explicit policy routes with rollback on failure.
- Added TUN device readiness checks, timeout/interval settings and cleanup of TUN rules/routes.
- Added v1-v3 UCI migration to the independent mode fields.
- Expanded LuCI labels, translations, debug output and regression tests for TUN and independent modes.

## 2026.04.08.legacy3

- Removed every IPv6 nat/REDIRECT rule and all `NIK_NAT_*_V6` chains.
- Reworked IPv6 TCP, UDP and port-53 DNS interception to use mangle/TPROXY only.
- Added IPv6 router OUTPUT marking and policy routing for TCP, UDP and DNS, not only UDP.
- Removed the `ip6tables-mod-nat` dependency and all runtime checks for an IPv6 REDIRECT target.
- Updated LuCI descriptions, debug output and documentation to state the asymmetric IPv4/IPv6 data paths.
- Added regression checks that fail if the IPv6 rules contain `*nat`, `REDIRECT`, `NIK_NAT_*_V6`, or any `ip6tables -t nat` access.

## 2026.04.08.legacy2 (superseded by legacy3)

- Added IPv6 TCP REDIRECT, UDP TPROXY and router/LAN DNS hijacking through ip6tables.
- Added `NIK_NAT_*_V6` and `NIK_MGL_*_V6` chains with the same layout as IPv4.
- Added IPv6 policy routing for router-originated UDP and independent bridge netfilter restoration.
- Added `family inet6` reserved/China ipsets and packaged `geoip6_cn.txt`.
- Added IPv6 LAN ACL selectors and fixed cross-family selector fallback behavior.
- Added LuCI IPv6 proxy, DNS, ACL, bypass and reserved-address controls.
- Added `ip6tables` and `ip6tables-mod-nat` dependencies.
- Expanded debug output and regression tests for dual-stack rule generation.

## 2026.04.08.legacy1

- Replaced `mixin.uc` with `mixin.sh` using OpenWrt `jshn` and `yq`.
- Replaced `hijack.ut`/firewall4/nftables with a firewall3/iptables IPv4 backend.
- Added TCP REDIRECT, UDP TPROXY, DNS hijack and policy routing.
- Added short explicit `NIK_NAT_*_V4` and `NIK_MGL_*_V4` chain names.
- Added `nik_reserved_v4` and `nik_china_v4` atomic ipsets.
- Added Mihomo core mark `0x82/0xFF` for loop avoidance.
- Replaced rpcd-ucode `luci.nikki` with `/usr/libexec/nikki-rpc` and `fs.exec`.
- Limited the LuCI transparent proxy modes to TCP Redirect and UDP TPROXY.
- Removed installed ucode and nftables assets from the legacy package.
- Fixed package feed integration to link each package directory independently.
- Added simulated mixin and iptables rule-generation regression tests.
- Removed upstream CI workflows that target modern OpenWrt branches.
