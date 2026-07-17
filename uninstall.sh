#!/bin/sh

set -eu

if ! command -v opkg >/dev/null 2>&1; then
	echo "This helper supports opkg-based OpenWrt only." >&2
	exit 1
fi

for package in $(opkg list-installed 'luci-i18n-nikki-*' 2>/dev/null | awk '{print $1}'); do
	opkg remove "$package" || true
done
opkg remove luci-app-nikki || true
opkg remove nikki || true

rm -f /etc/config/nikki
rm -rf /etc/nikki /var/log/nikki /var/run/nikki
uci -q delete firewall.nikki || true
uci -q commit firewall || true
/etc/init.d/firewall restart >/dev/null 2>&1 || true

echo "Nikki Legacy removed. Mihomo was left installed intentionally."
