#!/bin/sh

. /etc/nikki/scripts/include.sh

prepare_files

cat <<'EOF_HEAD'
# Nikki Legacy Debug Info

## Build scope

```text
OpenWrt 21.02-class firewall3/xtables backend
IPv4: TCP REDIRECT/TPROXY/TUN + UDP TPROXY/TUN + DNS REDIRECT/TUN
IPv6: TCP/UDP TPROXY/TUN + DNS TPROXY/TUN
```

## System

```text
EOF_HEAD
cat /etc/openwrt_release 2>/dev/null
cat <<'EOF_KERNEL'
```

## Kernel

```text
EOF_KERNEL
uname -a
cat <<'EOF_APP'
```

## Packages

```text
EOF_APP
opkg list-installed 'nikki' 'luci-app-nikki' 'mihomo-*' 2>/dev/null
opkg list-installed 'firewall' 'iptables*' 'ip6tables*' 'ipset' 'ip-full' 2>/dev/null
cat <<'EOF_CONFIG'
```

## Configuration (redacted)

```uci
EOF_CONFIG
uci show nikki 2>/dev/null | sed -E \
	-e "s/(api_secret|password|url|info_url)='[^']*'/\1='*'/g" \
	-e "s/(\.ip|\.ip6|\.mac)='[^']*'/\1='*'/g"
cat <<'EOF_PROFILE'
```

## Runtime profile (nodes removed)

```json
EOF_PROFILE
if [ -r "$RUN_PROFILE_PATH" ]; then
	yq -M -p yaml -o json '
		del(.proxies) |
		del(."proxy-providers") |
		.secret = "*" |
		.authentication = []
	' "$RUN_PROFILE_PATH" 2>/dev/null
fi
cat <<'EOF_RULES4'
```

## IPv4 policy rules and route table

```text
EOF_RULES4
ip -4 rule list
printf '%s\n' '-- TPROXY table --'
ip -4 route list table "$(uci -q get nikki.routing.tproxy_route_table || echo 80)" 2>/dev/null
printf '%s\n' '-- TUN table --'
ip -4 route list table "$(uci -q get nikki.routing.tun_route_table || echo 81)" 2>/dev/null
cat <<'EOF_RULES6'
```

## IPv6 policy rules and route table

```text
EOF_RULES6
ip -6 rule list
printf '%s\n' '-- TPROXY table --'
ip -6 route list table "$(uci -q get nikki.routing.tproxy_route_table || echo 80)" 2>/dev/null
printf '%s\n' '-- TUN table --'
ip -6 route list table "$(uci -q get nikki.routing.tun_route_table || echo 81)" 2>/dev/null
cat <<'EOF_IPTABLES'
```

## Nikki IPv4 iptables rules

```text
EOF_IPTABLES
iptables-save 2>/dev/null | grep -E '(^\*|^:NIK_|NIK_)'
cat <<'EOF_IP6TABLES'
```

## Nikki IPv6 ip6tables rules

```text
EOF_IP6TABLES
ip6tables-save 2>/dev/null | grep -E '(^\*|^:NIK_|NIK_)'
cat <<'EOF_IPSET'
```

## Nikki ipsets

```text
EOF_IPSET
for set_name in nik_reserved_v4 nik_china_v4 nik_reserved_v6 nik_china_v6; do
	ipset list "$set_name" 2>/dev/null
done
cat <<'EOF_MODULES'
```

## Required extensions

```text
EOF_MODULES
for cmd in iptables ip6tables; do
	"$cmd" -t nat -j REDIRECT -h >/dev/null 2>&1 && echo "$cmd REDIRECT: available" || echo "$cmd REDIRECT: missing"
	"$cmd" -t mangle -j TPROXY -h >/dev/null 2>&1 && echo "$cmd TPROXY: available" || echo "$cmd TPROXY: missing"
	"$cmd" -t mangle -j MARK -h >/dev/null 2>&1 && echo "$cmd MARK/TUN: available" || echo "$cmd MARK/TUN: missing"
	"$cmd" -m owner -h >/dev/null 2>&1 && echo "$cmd owner: available" || echo "$cmd owner: missing"
	"$cmd" -m set -h >/dev/null 2>&1 && echo "$cmd set: available" || echo "$cmd set: missing"
	"$cmd" -m dscp -h >/dev/null 2>&1 && echo "$cmd dscp: available" || echo "$cmd dscp: missing"
done
cat <<'EOF_SERVICE'
```

## Service

```text
EOF_SERVICE
/etc/init.d/nikki info 2>/dev/null
printf '%s\n' '```'
