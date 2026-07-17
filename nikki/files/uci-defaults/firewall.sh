#!/bin/sh

. "$IPKG_INSTROOT/etc/nikki/scripts/include.sh"

# firewall3 script include: restore Nikki chains after every firewall reload.
uci -q batch <<-EOF_UCI >/dev/null
	delete firewall.nikki
	set firewall.nikki=include
	set firewall.nikki.type=script
	set firewall.nikki.path=$FIREWALL_INCLUDE_SH
	set firewall.nikki.reload=1
	commit firewall
EOF_UCI

exit 0
