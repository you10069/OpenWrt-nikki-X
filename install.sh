#!/bin/sh

set -eu

if ! command -v opkg >/dev/null 2>&1; then
	echo "This helper supports opkg-based OpenWrt only." >&2
	exit 1
fi
if ! command -v fw3 >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1 || ! command -v ip6tables >/dev/null 2>&1; then
	echo "firewall3/fw3, iptables and ip6tables are required." >&2
	exit 1
fi

if [ "$#" -gt 0 ]; then
	opkg install "$@"
else
	set -- ./*.ipk
	[ -e "$1" ] || {
		echo "No local IPK files found. Pass package paths explicitly." >&2
		exit 2
	}
	opkg install "$@"
fi

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/firewall restart >/dev/null 2>&1 || true

echo "Local Nikki Legacy packages installed. Configure it in LuCI before enabling the service."
