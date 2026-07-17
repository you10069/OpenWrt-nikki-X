# Nikki Legacy changelog

## 2026.04.08.legacy2

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
