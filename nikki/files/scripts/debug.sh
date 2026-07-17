#!/bin/sh

. /etc/nikki/scripts/include.sh

prepare_files

cat <<'EOF_HEAD'
# Nikki Legacy Debug Info

## Build scope

```text
OpenWrt 21.02-class firewall3/iptables backend
IPv4 TCP REDIRECT + UDP TPROXY
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
opkg list-installed 'firewall' 'iptables*' 'ipset' 'ip-full' 2>/dev/null
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
cat <<'EOF_RULES'
```

## IPv4 policy rules

```text
EOF_RULES
ip -4 rule list
cat <<'EOF_ROUTE'
```

## TPROXY route table

```text
EOF_ROUTE
ip -4 route list table "$(uci -q get nikki.routing.tproxy_route_table || echo 80)" 2>/dev/null
cat <<'EOF_IPTABLES'
```

## Nikki iptables rules

```text
EOF_IPTABLES
iptables-save 2>/dev/null | grep -E '(^\*|^:NIK_|NIK_)'
cat <<'EOF_IPSET'
```

## Nikki ipsets

```text
EOF_IPSET
for set_name in nik_reserved_v4 nik_china_v4; do
	ipset list "$set_name" 2>/dev/null
done
cat <<'EOF_MODULES'
```

## Required extensions

```text
EOF_MODULES
iptables -j TPROXY -h >/dev/null 2>&1 && echo 'TPROXY: available' || echo 'TPROXY: missing'
iptables -m owner -h >/dev/null 2>&1 && echo 'owner: available' || echo 'owner: missing'
iptables -m set -h >/dev/null 2>&1 && echo 'set: available' || echo 'set: missing'
iptables -m dscp -h >/dev/null 2>&1 && echo 'dscp: available' || echo 'dscp: missing'
cat <<'EOF_SERVICE'
```

## Service

```text
EOF_SERVICE
/etc/init.d/nikki info 2>/dev/null
printf '%s\n' '```'
