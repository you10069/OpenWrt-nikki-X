#!/bin/sh

# Nikki legacy firewall3/xtables backend.
# Data plane:
# - IPv4 TCP: disabled / REDIRECT / TPROXY / TUN.
# - IPv4 UDP: disabled / TPROXY / TUN.
# - IPv6 TCP: disabled / REDIRECT / TPROXY / TUN.
# - IPv6 UDP: disabled / TPROXY / TUN.
# - IPv4 DNS: REDIRECT to Mihomo dns.listen, TPROXY, or route through TUN.
# - IPv6 DNS: REDIRECT to Mihomo dns.listen, TPROXY, or route through TUN.

. /lib/functions.sh
. /etc/nikki/scripts/include.sh

IPT4="${IPT4:-iptables}"
IPT6="${IPT6:-ip6tables}"
IPT4_RESTORE="${IPT4_RESTORE:-iptables-restore}"
IPT6_RESTORE="${IPT6_RESTORE:-ip6tables-restore}"
IPSET="${IPSET:-ipset}"
LOCK_DIR="${LOCK_DIR:-/var/lock/nikki-fw3.lock}"
RULES_FILE_V4="$TEMP_DIR/iptables-v4.rules"
RULES_FILE_V6="$TEMP_DIR/ip6tables-v6.rules"
IPSET_FILE="$TEMP_DIR/ipset.rules"
CHINA_IP4_FILE="${CHINA_IP4_FILE:-/etc/nikki/ipset/geoip_cn.txt}"
CHINA_IP6_FILE="${CHINA_IP6_FILE:-/etc/nikki/ipset/geoip6_cn.txt}"

NAT_PRE_DNS_V4="NIK_NAT_PRE_DNS_V4"
NAT_PRE_TCP_V4="NIK_NAT_PRE_TCP_V4"
NAT_OUT_DNS_V4="NIK_NAT_OUT_DNS_V4"
NAT_OUT_TCP_V4="NIK_NAT_OUT_TCP_V4"

NAT_PRE_DNS_V6="NIK_NAT_PRE_DNS_V6"
NAT_PRE_TCP_V6="NIK_NAT_PRE_TCP_V6"
NAT_OUT_DNS_V6="NIK_NAT_OUT_DNS_V6"
NAT_OUT_TCP_V6="NIK_NAT_OUT_TCP_V6"

MGL_PRE_CTRL_V4="NIK_MGL_PRE_CTRL_V4"
MGL_PRE_TPROXY_V4="NIK_MGL_PRE_TPROXY_V4"
MGL_PRE_TUN_V4="NIK_MGL_PRE_TUN_V4"
MGL_OUT_MARK_V4="NIK_MGL_OUT_MARK_V4"
MGL_OUT_TUN_V4="NIK_MGL_OUT_TUN_V4"
FLT_IN_TUN_V4="NIK_FLT_IN_TUN_V4"
FLT_FWD_TUN_V4="NIK_FLT_FWD_TUN_V4"

MGL_PRE_CTRL_V6="NIK_MGL_PRE_CTRL_V6"
MGL_PRE_TPROXY_V6="NIK_MGL_PRE_TPROXY_V6"
MGL_PRE_TUN_V6="NIK_MGL_PRE_TUN_V6"
MGL_OUT_MARK_V6="NIK_MGL_OUT_MARK_V6"
MGL_OUT_TUN_V6="NIK_MGL_OUT_TUN_V6"
FLT_IN_TUN_V6="NIK_FLT_IN_TUN_V6"
FLT_FWD_TUN_V6="NIK_FLT_FWD_TUN_V6"

SET_RESERVED_V4="nik_reserved_v4"
SET_RESERVED_V4_TMP="nik_reserved_v4_t"
SET_CHINA_V4="nik_china_v4"
SET_CHINA_V4_TMP="nik_china_v4_t"
SET_RESERVED_V6="nik_reserved_v6"
SET_RESERVED_V6_TMP="nik_reserved_v6_t"
SET_CHINA_V6="nik_china_v6"
SET_CHINA_V6_TMP="nik_china_v6_t"

acquire_lock() {
	local count=0
	mkdir -p /var/lock
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		count=$((count + 1))
		[ "$count" -lt 100 ] || return 1
		sleep 0.1
	done
	trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
}

release_lock() {
	rmdir "$LOCK_DIR" 2>/dev/null
	trap - EXIT INT TERM
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
mode_is() { [ "$1" = "$2" ]; }
mode_active() { [ -n "$1" ] && [ "$1" != disable ]; }

_LIST_COUNT=0
_count_list_item() { _LIST_COUNT=$((_LIST_COUNT + 1)); }
list_count() {
	_LIST_COUNT=0
	config_list_foreach "$1" "$2" _count_list_item
	echo "$_LIST_COUNT"
}

valid_port() {
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

extract_listen_port() {
	printf '%s\n' "$1" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p; t; /^[0-9][0-9]*$/p'
}

load_runtime_endpoints() {
	local redirect_listener tproxy_listener tun_listener dns_listen
	REDIR_PORT=''; TPROXY_PORT=''; DNS_PORT=''; DNS_LISTEN=''; TUN_DEVICE=''
	config_get redirect_listener core redirect_listener_name redir-in
	config_get tproxy_listener core tproxy_listener_name tproxy-in
	config_get tun_listener core tun_listener_name tun-in

	if mode_is "$IPV4_TCP_MODE" redirect || mode_is "$IPV6_TCP_MODE" redirect; then
		REDIR_PORT="$(REDIRECT_LISTENER="$redirect_listener" yq -M -r '."redir-port" // (.listeners[]? | select(.name == env(REDIRECT_LISTENER) and .type == "redir") | .port) // ""' "$RUN_PROFILE_PATH" </dev/null 2>/dev/null)"
		valid_port "$REDIR_PORT" || return 1
	fi

	if [ "$TPROXY_ACTIVE_V4" -eq 1 ] || [ "$TPROXY_ACTIVE_V6" -eq 1 ]; then
		TPROXY_PORT="$(TPROXY_LISTENER="$tproxy_listener" yq -M -r '."tproxy-port" // (.listeners[]? | select(.name == env(TPROXY_LISTENER) and .type == "tproxy") | .port) // ""' "$RUN_PROFILE_PATH" </dev/null 2>/dev/null)"
		valid_port "$TPROXY_PORT" || return 1
	fi

	if mode_is "$IPV4_DNS_MODE" redirect || mode_is "$IPV6_DNS_MODE" redirect; then
		dns_listen="$(yq -M -r '.dns.listen // ""' "$RUN_PROFILE_PATH" </dev/null 2>/dev/null)"
		DNS_LISTEN="$dns_listen"
		DNS_PORT="$(extract_listen_port "$dns_listen")"
		valid_port "$DNS_PORT" || return 1
		if mode_is "$IPV6_DNS_MODE" redirect; then
			[ "$dns_listen" = "[::]:$DNS_PORT" ] || return 1
		fi
	fi

	if [ "$TUN_ACTIVE_V4" -eq 1 ] || [ "$TUN_ACTIVE_V6" -eq 1 ]; then
		TUN_DEVICE="$(TUN_LISTENER="$tun_listener" yq -M -r '(.tun | select(.enable == true) | .device) // (.listeners[]? | select(.name == env(TUN_LISTENER) and .type == "tun") | .device) // ""' "$RUN_PROFILE_PATH" </dev/null 2>/dev/null)"
		[ -n "$TUN_DEVICE" ] || return 1
		case "$TUN_DEVICE" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
	fi
	return 0
}

resolve_network_device() {
	local network="$1" status device
	status="$(ubus call "network.interface.${network}" status 2>/dev/null)"
	device="$(printf '%s' "$status" | jsonfilter -e '@.l3_device' 2>/dev/null)"
	[ -n "$device" ] || device="$(printf '%s' "$status" | jsonfilter -e '@.device' 2>/dev/null)"
	[ -n "$device" ] && printf '%s\n' "$device"
}

LAN_DEVICES=""
_add_lan_device() {
	local network="$1" device
	device="$(resolve_network_device "$network")"
	[ -n "$device" ] || return 0
	case " $LAN_DEVICES " in *" $device "*) ;; *) LAN_DEVICES="$LAN_DEVICES $device" ;; esac
}

valid_ipv4_or_cidr() {
	printf '%s\n' "$1" | awk -F/ '
		BEGIN { ok = 1 }
		NF < 1 || NF > 2 { ok = 0; exit }
		NF == 2 && ($2 !~ /^[0-9]+$/ || $2 < 0 || $2 > 32) { ok = 0; exit }
		{
			n = split($1, oct, ".")
			if (n != 4) { ok = 0; exit }
			for (i = 1; i <= 4; i++) if (oct[i] !~ /^[0-9]+$/ || oct[i] < 0 || oct[i] > 255) { ok = 0; exit }
		}
		END { exit(ok && NR == 1 ? 0 : 1) }
	'
}

valid_ipv6_or_cidr() {
	local value="$1" address prefix
	case "$value" in ''|*[!0-9a-fA-F:./]*) return 1 ;; esac
	address="${value%%/*}"
	[ "$address" != "$value" ] && prefix="${value#*/}" || prefix=""
	case "$address" in *:*) ;; *) return 1 ;; esac
	if [ -n "$prefix" ]; then
		case "$prefix" in ''|*[!0-9]*) return 1 ;; esac
		[ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ] || return 1
	fi
	return 0
}

prepare_ipsets() {
	: > "$IPSET_FILE"
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	create $SET_RESERVED_V4 hash:net family inet hashsize 128 maxelem 1024 -exist
	create $SET_RESERVED_V4_TMP hash:net family inet hashsize 128 maxelem 1024 -exist
	flush $SET_RESERVED_V4_TMP
	EOF_IPSET
	_add_reserved_ip4() { valid_ipv4_or_cidr "$1" && printf 'add %s %s -exist\n' "$SET_RESERVED_V4_TMP" "$1" >> "$IPSET_FILE"; }
	config_list_foreach proxy reserved_ip _add_reserved_ip4
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_RESERVED_V4_TMP $SET_RESERVED_V4
	destroy $SET_RESERVED_V4_TMP
	create $SET_CHINA_V4 hash:net family inet hashsize 4096 maxelem 65536 -exist
	create $SET_CHINA_V4_TMP hash:net family inet hashsize 4096 maxelem 65536 -exist
	flush $SET_CHINA_V4_TMP
	EOF_IPSET
	[ "$BYPASS_CHINA_V4" -eq 1 ] && [ -r "$CHINA_IP4_FILE" ] && awk -v set="$SET_CHINA_V4_TMP" 'NF && $1 !~ /^#/ { print "add " set " " $1 " -exist" }' "$CHINA_IP4_FILE" >> "$IPSET_FILE"
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_CHINA_V4_TMP $SET_CHINA_V4
	destroy $SET_CHINA_V4_TMP
	create $SET_RESERVED_V6 hash:net family inet6 hashsize 128 maxelem 1024 -exist
	create $SET_RESERVED_V6_TMP hash:net family inet6 hashsize 128 maxelem 1024 -exist
	flush $SET_RESERVED_V6_TMP
	EOF_IPSET
	_add_reserved_ip6() { valid_ipv6_or_cidr "$1" && printf 'add %s %s -exist\n' "$SET_RESERVED_V6_TMP" "$1" >> "$IPSET_FILE"; }
	config_list_foreach proxy reserved_ip6 _add_reserved_ip6
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_RESERVED_V6_TMP $SET_RESERVED_V6
	destroy $SET_RESERVED_V6_TMP
	create $SET_CHINA_V6 hash:net family inet6 hashsize 4096 maxelem 65536 -exist
	create $SET_CHINA_V6_TMP hash:net family inet6 hashsize 4096 maxelem 65536 -exist
	flush $SET_CHINA_V6_TMP
	EOF_IPSET
	[ "$BYPASS_CHINA_V6" -eq 1 ] && [ -r "$CHINA_IP6_FILE" ] && awk -v set="$SET_CHINA_V6_TMP" 'NF && $1 !~ /^#/ { print "add " set " " $1 " -exist" }' "$CHINA_IP6_FILE" >> "$IPSET_FILE"
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_CHINA_V6_TMP $SET_CHINA_V6
	destroy $SET_CHINA_V6_TMP
	EOF_IPSET
	$IPSET restore < "$IPSET_FILE"
}

remove_jump() {
	local cmd="$1" table="$2" builtin="$3" chain="$4"
	while "$cmd" -t "$table" -C "$builtin" -j "$chain" >/dev/null 2>&1; do
		"$cmd" -t "$table" -D "$builtin" -j "$chain" >/dev/null 2>&1 || break
	done
}
remove_chain() {
	local cmd="$1" table="$2" chain="$3"
	"$cmd" -t "$table" -F "$chain" >/dev/null 2>&1
	"$cmd" -t "$table" -X "$chain" >/dev/null 2>&1
}

remove_ipv4_rules() {
	remove_jump "$IPT4" nat PREROUTING "$NAT_PRE_DNS_V4"
	remove_jump "$IPT4" nat PREROUTING "$NAT_PRE_TCP_V4"
	remove_jump "$IPT4" nat OUTPUT "$NAT_OUT_DNS_V4"
	remove_jump "$IPT4" nat OUTPUT "$NAT_OUT_TCP_V4"
	remove_jump "$IPT4" mangle PREROUTING "$MGL_PRE_CTRL_V4"
	remove_jump "$IPT4" mangle OUTPUT "$MGL_OUT_MARK_V4"
	remove_jump "$IPT4" mangle OUTPUT "$MGL_OUT_TUN_V4"
	remove_jump "$IPT4" filter INPUT "$FLT_IN_TUN_V4"
	remove_jump "$IPT4" filter FORWARD "$FLT_FWD_TUN_V4"
	for chain in "$NAT_PRE_DNS_V4" "$NAT_PRE_TCP_V4" "$NAT_OUT_DNS_V4" "$NAT_OUT_TCP_V4"; do remove_chain "$IPT4" nat "$chain"; done
	for chain in "$MGL_PRE_CTRL_V4" "$MGL_PRE_TPROXY_V4" "$MGL_PRE_TUN_V4" "$MGL_OUT_MARK_V4" "$MGL_OUT_TUN_V4"; do remove_chain "$IPT4" mangle "$chain"; done
	for chain in "$FLT_IN_TUN_V4" "$FLT_FWD_TUN_V4"; do remove_chain "$IPT4" filter "$chain"; done
}

remove_ipv6_rules() {
	remove_jump "$IPT6" nat PREROUTING "$NAT_PRE_DNS_V6"
	remove_jump "$IPT6" nat PREROUTING "$NAT_PRE_TCP_V6"
	remove_jump "$IPT6" nat OUTPUT "$NAT_OUT_DNS_V6"
	remove_jump "$IPT6" nat OUTPUT "$NAT_OUT_TCP_V6"
	remove_jump "$IPT6" mangle PREROUTING "$MGL_PRE_CTRL_V6"
	remove_jump "$IPT6" mangle OUTPUT "$MGL_OUT_MARK_V6"
	remove_jump "$IPT6" mangle OUTPUT "$MGL_OUT_TUN_V6"
	remove_jump "$IPT6" filter INPUT "$FLT_IN_TUN_V6"
	remove_jump "$IPT6" filter FORWARD "$FLT_FWD_TUN_V6"
	for chain in "$NAT_PRE_DNS_V6" "$NAT_PRE_TCP_V6" "$NAT_OUT_DNS_V6" "$NAT_OUT_TCP_V6"; do remove_chain "$IPT6" nat "$chain"; done
	for chain in "$MGL_PRE_CTRL_V6" "$MGL_PRE_TPROXY_V6" "$MGL_PRE_TUN_V6" "$MGL_OUT_MARK_V6" "$MGL_OUT_TUN_V6"; do remove_chain "$IPT6" mangle "$chain"; done
	for chain in "$FLT_IN_TUN_V6" "$FLT_FWD_TUN_V6"; do remove_chain "$IPT6" filter "$chain"; done
}

remove_rules_only() { remove_ipv4_rules; remove_ipv6_rules; }
remove_all() {
	acquire_lock || return 1
	remove_rules_only
	for set_name in "$SET_RESERVED_V4" "$SET_RESERVED_V4_TMP" "$SET_CHINA_V4" "$SET_CHINA_V4_TMP" "$SET_RESERVED_V6" "$SET_RESERVED_V6_TMP" "$SET_CHINA_V6" "$SET_CHINA_V6_TMP"; do
		$IPSET destroy "$set_name" >/dev/null 2>&1
	done
	release_lock
}

rule() { printf '%s\n' "$*" >> "$RULES_FILE"; }

normalize_port_tokens() {
	local input="$1" token count=0 chunk="" first last normalized
	PORT_ALL=0; PORT_CHUNKS=""
	[ -n "$input" ] || input="0-65535"
	input="$(printf '%s' "$input" | tr ',' ' ')"
	for token in $input; do
		case "$token" in 0-65535|0:65535) PORT_ALL=1; PORT_CHUNKS=""; return 0 ;; esac
		if printf '%s\n' "$token" | grep -Eq '^[0-9]+$'; then
			valid_port "$token" || continue; normalized="$token"
		elif printf '%s\n' "$token" | grep -Eq '^[0-9]+[-:][0-9]+$'; then
			first="${token%%[-:]*}"; last="${token#*[-:]}"
			valid_port "$first" && valid_port "$last" && [ "$first" -le "$last" ] || continue
			normalized="$first:$last"
		else continue; fi
		[ -z "$chunk" ] && chunk="$normalized" || chunk="$chunk,$normalized"
		count=$((count + 1))
		if [ "$count" -eq 15 ]; then PORT_CHUNKS="${PORT_CHUNKS}${PORT_CHUNKS:+
}${chunk}"; chunk=""; count=0; fi
	done
	[ -z "$chunk" ] || PORT_CHUNKS="${PORT_CHUNKS}${PORT_CHUNKS:+
}${chunk}"
	[ -n "$PORT_CHUNKS" ] || PORT_ALL=1
}

emit_port_action() {
	local chain="$1" base="$2" target="$3" chunk oldifs
	if [ "$PORT_ALL" -eq 1 ]; then rule "-A $chain $base $target"; return; fi
	oldifs="$IFS"; IFS='
'
	for chunk in $PORT_CHUNKS; do [ -n "$chunk" ] && rule "-A $chain $base -m multiport --dports $chunk $target"; done
	IFS="$oldifs"
}

emit_dscp_bypass() {
	local chain="$1" base="$2" value
	_emit_dscp() { value="$1"; case "$value" in ''|*[!0-9]*) return ;; esac; [ "$value" -le 63 ] && rule "-A $chain $base -m dscp --dscp $value -j RETURN"; }
	config_list_foreach proxy bypass_dscp _emit_dscp
}
emit_fwmark_bypass() {
	local chain="$1" base="$2" value mark mask
	_emit_fwmark() {
		value="$1"; mark="${value%%/*}"; [ "$mark" = "$value" ] && mask="0xFFFFFFFF" || mask="${value#*/}"
		case "$mark/$mask" in *[!0-9a-fA-FxX/]*|/) return ;; esac
		rule "-A $chain $base -m mark --mark $mark/$mask -j RETURN"
	}
	config_list_foreach proxy bypass_fwmark _emit_fwmark
}
emit_common_bypass() {
	local chain="$1" base="$2"
	rule "-A $chain $base -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
	rule "-A $chain $base -m mark --mark $TPROXY_MARK/$TPROXY_MASK -j RETURN"
	rule "-A $chain $base -m mark --mark $TUN_MARK/$TUN_MASK -j RETURN"
	rule "-A $chain $base -m addrtype --dst-type LOCAL -j RETURN"
	rule "-A $chain $base -m set --match-set $SET_RESERVED dst -j RETURN"
	[ "$BYPASS_CHINA" -eq 1 ] && rule "-A $chain $base -m set --match-set $SET_CHINA dst -j RETURN"
	emit_dscp_bypass "$chain" "$base"
	emit_fwmark_bypass "$chain" "$base"
}

user_exists() { grep -q "^$1:" /etc/passwd 2>/dev/null; }
group_exists() { grep -q "^$1:" /etc/group 2>/dev/null; }

LAN_CHAIN=""; LAN_BASE=""; LAN_KIND=""; LAN_IP_OPTION=""; LAN_VALIDATE_FN=""; LAN_DNS=0; LAN_ACL_PROXY=0
_emit_lan_target() {
	local selector="$1" dns="$2" proxy="$3" base
	base="$LAN_BASE $selector"
	case "$LAN_KIND" in
		dns_redirect)
			if [ "$dns" -eq 1 ]; then
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
			else
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi ;;
		dns_tproxy)
			if [ "$dns" -eq 1 ]; then
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j $MGL_PRE_TPROXY"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j $MGL_PRE_TPROXY"
			else
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi ;;
		dns_tun)
			if [ "$dns" -eq 1 ]; then
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j $MGL_PRE_TUN"
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j $MGL_PRE_TUN"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j RETURN"
			else
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi ;;
		tcp_redirect|tcp_tproxy|tcp_tun)
			[ "$FAMILY_DNS_ACTIVE" -eq 1 ] && rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j RETURN"
			if [ "$proxy" -eq 1 ]; then
				case "$LAN_KIND" in
					tcp_redirect) emit_port_action "$LAN_CHAIN" "$base -p tcp" "-j REDIRECT --to-ports $REDIR_PORT" ;;
					tcp_tproxy) emit_port_action "$LAN_CHAIN" "$base -p tcp" "-j $MGL_PRE_TPROXY" ;;
					tcp_tun) emit_port_action "$LAN_CHAIN" "$base -p tcp" "-j $MGL_PRE_TUN" ;;
				esac
			fi
			rule "-A $LAN_CHAIN $base -p tcp -j RETURN" ;;
		udp_tproxy|udp_tun)
			[ "$FAMILY_DNS_ACTIVE" -eq 1 ] && rule "-A $LAN_CHAIN $base -p udp --dport 53 -j RETURN"
			if [ "$proxy" -eq 1 ]; then
				[ "$LAN_KIND" = udp_tproxy ] && emit_port_action "$LAN_CHAIN" "$base -p udp" "-j $MGL_PRE_TPROXY"
				[ "$LAN_KIND" = udp_tun ] && emit_port_action "$LAN_CHAIN" "$base -p udp" "-j $MGL_PRE_TUN"
			fi
			rule "-A $LAN_CHAIN $base -p udp -j RETURN" ;;
	esac
}
_emit_lan_ip() { "$LAN_VALIDATE_FN" "$1" && _emit_lan_target "-s $1" "$LAN_DNS" "$LAN_ACL_PROXY"; }
_emit_lan_mac() { printf '%s' "$1" | grep -Eqi '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' && _emit_lan_target "-m mac --mac-source $1" "$LAN_DNS" "$LAN_ACL_PROXY"; }
_emit_lan_acl_section() {
	local section="$1" enabled selector_count
	config_get_bool enabled "$section" enabled 0; [ "$enabled" -eq 1 ] || return 0
	config_get_bool LAN_DNS "$section" dns 0; config_get_bool LAN_ACL_PROXY "$section" proxy 0
	selector_count=$(( $(list_count "$section" ip) + $(list_count "$section" ip6) + $(list_count "$section" mac) ))
	config_list_foreach "$section" "$LAN_IP_OPTION" _emit_lan_ip
	config_list_foreach "$section" mac _emit_lan_mac
	[ "$selector_count" -eq 0 ] && _emit_lan_target "" "$LAN_DNS" "$LAN_ACL_PROXY"
}
emit_lan_acl() {
	LAN_CHAIN="$1"; LAN_BASE="-i $2"; LAN_KIND="$3"
	config_foreach _emit_lan_acl_section lan_access_control
}

RTR_CHAIN=""; RTR_KIND=""; RTR_DNS=0; RTR_PROXY=0; RTR_HAS_SELECTOR=0
_emit_router_target() {
	local selector="$1" base
	base="$selector"
	case "$RTR_KIND" in
		dns_redirect)
			if [ "$RTR_DNS" -eq 1 ]; then
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
			else
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi ;;
		dns_tproxy)
			if [ "$RTR_DNS" -eq 1 ]; then
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j MARK --set-xmark $TPROXY_MARK/$TPROXY_MASK"
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j MARK --set-xmark $TPROXY_MARK/$TPROXY_MASK"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j RETURN"
			else
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi ;;
		dns_tun)
			if [ "$RTR_DNS" -eq 1 ]; then
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j MARK --set-xmark $TUN_MARK/$TUN_MASK"
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j MARK --set-xmark $TUN_MARK/$TUN_MASK"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j RETURN"
			else
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi ;;
		tcp_redirect|tcp_tproxy|tcp_tun)
			[ "$FAMILY_DNS_ACTIVE" -eq 1 ] && rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j RETURN"
			if [ "$RTR_PROXY" -eq 1 ]; then
				case "$RTR_KIND" in
					tcp_redirect) emit_port_action "$RTR_CHAIN" "$base -p tcp" "-j REDIRECT --to-ports $REDIR_PORT" ;;
					tcp_tproxy) emit_port_action "$RTR_CHAIN" "$base -p tcp" "-j MARK --set-xmark $TPROXY_MARK/$TPROXY_MASK" ;;
					tcp_tun) emit_port_action "$RTR_CHAIN" "$base -p tcp" "-j MARK --set-xmark $TUN_MARK/$TUN_MASK" ;;
				esac
			fi
			rule "-A $RTR_CHAIN $base -p tcp -j RETURN" ;;
		udp_tproxy|udp_tun)
			[ "$FAMILY_DNS_ACTIVE" -eq 1 ] && rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
			if [ "$RTR_PROXY" -eq 1 ]; then
				[ "$RTR_KIND" = udp_tproxy ] && emit_port_action "$RTR_CHAIN" "$base -p udp" "-j MARK --set-xmark $TPROXY_MARK/$TPROXY_MASK"
				[ "$RTR_KIND" = udp_tun ] && emit_port_action "$RTR_CHAIN" "$base -p udp" "-j MARK --set-xmark $TUN_MARK/$TUN_MASK"
			fi
			rule "-A $RTR_CHAIN $base -p udp -j RETURN" ;;
	esac
}
_emit_router_user() { user_exists "$1" || return 0; RTR_HAS_SELECTOR=1; _emit_router_target "-m owner --uid-owner $1"; }
_emit_router_group() { group_exists "$1" || return 0; RTR_HAS_SELECTOR=1; _emit_router_target "-m owner --gid-owner $1"; }
_emit_router_acl_section() {
	local section="$1" enabled unsupported_cgroup
	config_get_bool enabled "$section" enabled 0; [ "$enabled" -eq 1 ] || return 0
	config_get_bool RTR_DNS "$section" dns 0; config_get_bool RTR_PROXY "$section" proxy 0
	RTR_HAS_SELECTOR=0
	config_list_foreach "$section" user _emit_router_user
	config_list_foreach "$section" group _emit_router_group
	unsupported_cgroup="$(list_count "$section" cgroup)"
	[ "$RTR_HAS_SELECTOR" -eq 0 ] && [ "$unsupported_cgroup" -eq 0 ] && _emit_router_target ""
}
emit_router_acl() { RTR_CHAIN="$1"; RTR_KIND="$2"; config_foreach _emit_router_acl_section router_access_control; }

select_ipv4_context() {
	RULES_FILE="$RULES_FILE_V4"
	NAT_PRE_DNS="$NAT_PRE_DNS_V4"; NAT_PRE_TCP="$NAT_PRE_TCP_V4"; NAT_OUT_DNS="$NAT_OUT_DNS_V4"; NAT_OUT_TCP="$NAT_OUT_TCP_V4"
	MGL_PRE_CTRL="$MGL_PRE_CTRL_V4"; MGL_PRE_TPROXY="$MGL_PRE_TPROXY_V4"; MGL_PRE_TUN="$MGL_PRE_TUN_V4"; MGL_OUT_MARK="$MGL_OUT_MARK_V4"; MGL_OUT_TUN="$MGL_OUT_TUN_V4"
	FLT_IN_TUN="$FLT_IN_TUN_V4"; FLT_FWD_TUN="$FLT_FWD_TUN_V4"
	SET_RESERVED="$SET_RESERVED_V4"; SET_CHINA="$SET_CHINA_V4"; BYPASS_CHINA="$BYPASS_CHINA_V4"
	LAN_IP_OPTION=ip; LAN_VALIDATE_FN=valid_ipv4_or_cidr
	FAMILY_DNS_ACTIVE=0; mode_active "$IPV4_DNS_MODE" && FAMILY_DNS_ACTIVE=1
}
select_ipv6_context() {
	RULES_FILE="$RULES_FILE_V6"
	NAT_PRE_DNS="$NAT_PRE_DNS_V6"; NAT_PRE_TCP="$NAT_PRE_TCP_V6"; NAT_OUT_DNS="$NAT_OUT_DNS_V6"; NAT_OUT_TCP="$NAT_OUT_TCP_V6"
	MGL_PRE_CTRL="$MGL_PRE_CTRL_V6"; MGL_PRE_TPROXY="$MGL_PRE_TPROXY_V6"; MGL_PRE_TUN="$MGL_PRE_TUN_V6"; MGL_OUT_MARK="$MGL_OUT_MARK_V6"; MGL_OUT_TUN="$MGL_OUT_TUN_V6"
	FLT_IN_TUN="$FLT_IN_TUN_V6"; FLT_FWD_TUN="$FLT_FWD_TUN_V6"
	SET_RESERVED="$SET_RESERVED_V6"; SET_CHINA="$SET_CHINA_V6"; BYPASS_CHINA="$BYPASS_CHINA_V6"
	LAN_IP_OPTION=ip6; LAN_VALIDATE_FN=valid_ipv6_or_cidr
	FAMILY_DNS_ACTIVE=0; mode_active "$IPV6_DNS_MODE" && FAMILY_DNS_ACTIVE=1
}

emit_tun_filter_table() {
	[ "$FAMILY_TUN_ACTIVE" -eq 1 ] || return 0
	cat >> "$RULES_FILE" <<-EOF_FILTER
	*filter
	:$FLT_IN_TUN - [0:0]
	:$FLT_FWD_TUN - [0:0]
	-I INPUT 1 -j $FLT_IN_TUN
	-I FORWARD 1 -j $FLT_FWD_TUN
	-A $FLT_IN_TUN -i $TUN_DEVICE -j ACCEPT
	-A $FLT_FWD_TUN -i $TUN_DEVICE -j ACCEPT
	-A $FLT_FWD_TUN -o $TUN_DEVICE -j ACCEPT
	COMMIT
	EOF_FILTER
}

generate_ipv4_rules() {
	select_ipv4_context; : > "$RULES_FILE"
	cat >> "$RULES_FILE" <<-EOF_NAT
	*nat
	:$NAT_PRE_DNS - [0:0]
	:$NAT_PRE_TCP - [0:0]
	:$NAT_OUT_DNS - [0:0]
	:$NAT_OUT_TCP - [0:0]
	EOF_NAT
	[ "$LAN_PROXY_ENABLED" -eq 1 ] && mode_is "$IPV4_TCP_MODE" redirect && rule "-I PREROUTING 1 -j $NAT_PRE_TCP"
	[ "$LAN_PROXY_ENABLED" -eq 1 ] && mode_is "$IPV4_DNS_MODE" redirect && rule "-I PREROUTING 1 -j $NAT_PRE_DNS"
	[ "$ROUTER_PROXY" -eq 1 ] && mode_is "$IPV4_TCP_MODE" redirect && rule "-I OUTPUT 1 -j $NAT_OUT_TCP"
	[ "$ROUTER_PROXY" -eq 1 ] && mode_is "$IPV4_DNS_MODE" redirect && rule "-I OUTPUT 1 -j $NAT_OUT_DNS"
	if [ "$LAN_PROXY_ENABLED" -eq 1 ]; then
		for dev in $LAN_DEVICES; do
			mode_is "$IPV4_DNS_MODE" redirect && emit_lan_acl "$NAT_PRE_DNS" "$dev" dns_redirect
			if mode_is "$IPV4_TCP_MODE" redirect; then emit_common_bypass "$NAT_PRE_TCP" "-i $dev -p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_lan_acl "$NAT_PRE_TCP" "$dev" tcp_redirect; fi
		done
	fi
	if [ "$ROUTER_PROXY" -eq 1 ]; then
		if mode_is "$IPV4_DNS_MODE" redirect; then rule "-A $NAT_OUT_DNS -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"; emit_router_acl "$NAT_OUT_DNS" dns_redirect; fi
		if mode_is "$IPV4_TCP_MODE" redirect; then emit_common_bypass "$NAT_OUT_TCP" "-p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_router_acl "$NAT_OUT_TCP" tcp_redirect; fi
	fi
	rule COMMIT

	cat >> "$RULES_FILE" <<-EOF_MGL
	*mangle
	:$MGL_PRE_CTRL - [0:0]
	:$MGL_PRE_TPROXY - [0:0]
	:$MGL_PRE_TUN - [0:0]
	:$MGL_OUT_MARK - [0:0]
	:$MGL_OUT_TUN - [0:0]
	EOF_MGL
	FAMILY_TUN_ACTIVE="$TUN_ACTIVE_V4"
	if [ "$TPROXY_ACTIVE_V4" -eq 1 ] || [ "$TUN_ACTIVE_V4" -eq 1 ]; then
		if [ "$LAN_PROXY_ENABLED" -eq 1 ] || { [ "$ROUTER_PROXY" -eq 1 ] && [ "$TPROXY_ACTIVE_V4" -eq 1 ]; }; then rule "-I PREROUTING 1 -j $MGL_PRE_CTRL"; fi
		# Emit TUN first and TPROXY second: repeated -I 1 leaves TPROXY ahead.
		[ "$ROUTER_PROXY" -eq 1 ] && [ "$TUN_ACTIVE_V4" -eq 1 ] && rule "-I OUTPUT 1 -j $MGL_OUT_TUN"
		[ "$ROUTER_PROXY" -eq 1 ] && [ "$TPROXY_ACTIVE_V4" -eq 1 ] && rule "-I OUTPUT 1 -j $MGL_OUT_MARK"
		if mode_is "$IPV4_TCP_MODE" tproxy || mode_is "$IPV4_DNS_MODE" tproxy; then rule "-A $MGL_PRE_TPROXY -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $TPROXY_MARK/$TPROXY_MASK"; fi
		if mode_is "$IPV4_UDP_MODE" tproxy || mode_is "$IPV4_DNS_MODE" tproxy; then rule "-A $MGL_PRE_TPROXY -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $TPROXY_MARK/$TPROXY_MASK"; fi
		if [ "$TUN_ACTIVE_V4" -eq 1 ]; then rule "-A $MGL_PRE_TUN -j MARK --set-xmark $TUN_MARK/$TUN_MASK"; rule "-A $MGL_PRE_TUN -j RETURN"; fi
		if [ "$ROUTER_PROXY" -eq 1 ] && [ "$TPROXY_ACTIVE_V4" -eq 1 ]; then
			if mode_is "$IPV4_TCP_MODE" tproxy || mode_is "$IPV4_DNS_MODE" tproxy; then rule "-A $MGL_PRE_CTRL -i lo -p tcp -m mark --mark $TPROXY_MARK/$TPROXY_MASK -j $MGL_PRE_TPROXY"; fi
			if mode_is "$IPV4_UDP_MODE" tproxy || mode_is "$IPV4_DNS_MODE" tproxy; then rule "-A $MGL_PRE_CTRL -i lo -p udp -m mark --mark $TPROXY_MARK/$TPROXY_MASK -j $MGL_PRE_TPROXY"; fi
		fi
		if [ "$LAN_PROXY_ENABLED" -eq 1 ]; then
			for dev in $LAN_DEVICES; do
				mode_is "$IPV4_DNS_MODE" tproxy && emit_lan_acl "$MGL_PRE_CTRL" "$dev" dns_tproxy
				mode_is "$IPV4_DNS_MODE" tun && emit_lan_acl "$MGL_PRE_CTRL" "$dev" dns_tun
				case "$IPV4_TCP_MODE" in
					tproxy) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" tcp_tproxy ;;
					tun) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" tcp_tun ;;
				esac
				case "$IPV4_UDP_MODE" in
					tproxy) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" udp_tproxy ;;
					tun) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" udp_tun ;;
				esac
			done
		fi
		if [ "$ROUTER_PROXY" -eq 1 ]; then
			if [ "$TPROXY_ACTIVE_V4" -eq 1 ]; then
				rule "-A $MGL_OUT_MARK -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
				mode_is "$IPV4_DNS_MODE" tproxy && emit_router_acl "$MGL_OUT_MARK" dns_tproxy
				case "$IPV4_TCP_MODE" in tproxy) emit_common_bypass "$MGL_OUT_MARK" "-p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_router_acl "$MGL_OUT_MARK" tcp_tproxy ;; esac
				case "$IPV4_UDP_MODE" in tproxy) emit_common_bypass "$MGL_OUT_MARK" "-p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_router_acl "$MGL_OUT_MARK" udp_tproxy ;; esac
			fi
			if [ "$TUN_ACTIVE_V4" -eq 1 ]; then
				rule "-A $MGL_OUT_TUN -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
				mode_is "$IPV4_DNS_MODE" tun && emit_router_acl "$MGL_OUT_TUN" dns_tun
				case "$IPV4_TCP_MODE" in tun) emit_common_bypass "$MGL_OUT_TUN" "-p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_router_acl "$MGL_OUT_TUN" tcp_tun ;; esac
				case "$IPV4_UDP_MODE" in tun) emit_common_bypass "$MGL_OUT_TUN" "-p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_router_acl "$MGL_OUT_TUN" udp_tun ;; esac
			fi
		fi
	fi
	rule COMMIT
	emit_tun_filter_table
}

generate_ipv6_rules() {
	select_ipv6_context; : > "$RULES_FILE"
	if mode_is "$IPV6_DNS_MODE" redirect || mode_is "$IPV6_TCP_MODE" redirect; then
		cat >> "$RULES_FILE" <<-EOF_NAT
		*nat
		:$NAT_PRE_DNS - [0:0]
		:$NAT_PRE_TCP - [0:0]
		:$NAT_OUT_DNS - [0:0]
		:$NAT_OUT_TCP - [0:0]
		EOF_NAT
		[ "$LAN_PROXY_ENABLED" -eq 1 ] && mode_is "$IPV6_TCP_MODE" redirect && rule "-I PREROUTING 1 -j $NAT_PRE_TCP"
		[ "$LAN_PROXY_ENABLED" -eq 1 ] && mode_is "$IPV6_DNS_MODE" redirect && rule "-I PREROUTING 1 -j $NAT_PRE_DNS"
		[ "$ROUTER_PROXY" -eq 1 ] && mode_is "$IPV6_TCP_MODE" redirect && rule "-I OUTPUT 1 -j $NAT_OUT_TCP"
		[ "$ROUTER_PROXY" -eq 1 ] && mode_is "$IPV6_DNS_MODE" redirect && rule "-I OUTPUT 1 -j $NAT_OUT_DNS"
		if [ "$LAN_PROXY_ENABLED" -eq 1 ]; then
			for dev in $LAN_DEVICES; do
				mode_is "$IPV6_DNS_MODE" redirect && emit_lan_acl "$NAT_PRE_DNS" "$dev" dns_redirect
				if mode_is "$IPV6_TCP_MODE" redirect; then emit_common_bypass "$NAT_PRE_TCP" "-i $dev -p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_lan_acl "$NAT_PRE_TCP" "$dev" tcp_redirect; fi
			done
		fi
		if [ "$ROUTER_PROXY" -eq 1 ]; then
			if mode_is "$IPV6_DNS_MODE" redirect; then rule "-A $NAT_OUT_DNS -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"; emit_router_acl "$NAT_OUT_DNS" dns_redirect; fi
			if mode_is "$IPV6_TCP_MODE" redirect; then emit_common_bypass "$NAT_OUT_TCP" "-p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_router_acl "$NAT_OUT_TCP" tcp_redirect; fi
		fi
		rule COMMIT
	fi

	cat >> "$RULES_FILE" <<-EOF_MGL
	*mangle
	:$MGL_PRE_CTRL - [0:0]
	:$MGL_PRE_TPROXY - [0:0]
	:$MGL_PRE_TUN - [0:0]
	:$MGL_OUT_MARK - [0:0]
	:$MGL_OUT_TUN - [0:0]
	EOF_MGL
	FAMILY_TUN_ACTIVE="$TUN_ACTIVE_V6"
	if [ "$TPROXY_ACTIVE_V6" -eq 1 ] || [ "$TUN_ACTIVE_V6" -eq 1 ]; then
		if [ "$LAN_PROXY_ENABLED" -eq 1 ] || { [ "$ROUTER_PROXY" -eq 1 ] && [ "$TPROXY_ACTIVE_V6" -eq 1 ]; }; then rule "-I PREROUTING 1 -j $MGL_PRE_CTRL"; fi
		[ "$ROUTER_PROXY" -eq 1 ] && [ "$TUN_ACTIVE_V6" -eq 1 ] && rule "-I OUTPUT 1 -j $MGL_OUT_TUN"
		[ "$ROUTER_PROXY" -eq 1 ] && [ "$TPROXY_ACTIVE_V6" -eq 1 ] && rule "-I OUTPUT 1 -j $MGL_OUT_MARK"
		if mode_is "$IPV6_TCP_MODE" tproxy || mode_is "$IPV6_DNS_MODE" tproxy; then rule "-A $MGL_PRE_TPROXY -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $TPROXY_MARK/$TPROXY_MASK"; fi
		if mode_is "$IPV6_UDP_MODE" tproxy || mode_is "$IPV6_DNS_MODE" tproxy; then rule "-A $MGL_PRE_TPROXY -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $TPROXY_MARK/$TPROXY_MASK"; fi
		if [ "$TUN_ACTIVE_V6" -eq 1 ]; then rule "-A $MGL_PRE_TUN -j MARK --set-xmark $TUN_MARK/$TUN_MASK"; rule "-A $MGL_PRE_TUN -j RETURN"; fi
		if [ "$ROUTER_PROXY" -eq 1 ] && [ "$TPROXY_ACTIVE_V6" -eq 1 ]; then
			if mode_is "$IPV6_TCP_MODE" tproxy || mode_is "$IPV6_DNS_MODE" tproxy; then rule "-A $MGL_PRE_CTRL -i lo -p tcp -m mark --mark $TPROXY_MARK/$TPROXY_MASK -j $MGL_PRE_TPROXY"; fi
			if mode_is "$IPV6_UDP_MODE" tproxy || mode_is "$IPV6_DNS_MODE" tproxy; then rule "-A $MGL_PRE_CTRL -i lo -p udp -m mark --mark $TPROXY_MARK/$TPROXY_MASK -j $MGL_PRE_TPROXY"; fi
		fi
		if [ "$LAN_PROXY_ENABLED" -eq 1 ]; then
			for dev in $LAN_DEVICES; do
				mode_is "$IPV6_DNS_MODE" tproxy && emit_lan_acl "$MGL_PRE_CTRL" "$dev" dns_tproxy
				mode_is "$IPV6_DNS_MODE" tun && emit_lan_acl "$MGL_PRE_CTRL" "$dev" dns_tun
				case "$IPV6_TCP_MODE" in
					tproxy) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" tcp_tproxy ;;
					tun) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" tcp_tun ;;
				esac
				case "$IPV6_UDP_MODE" in
					tproxy) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" udp_tproxy ;;
					tun) emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_lan_acl "$MGL_PRE_CTRL" "$dev" udp_tun ;;
				esac
			done
		fi
		if [ "$ROUTER_PROXY" -eq 1 ]; then
			if [ "$TPROXY_ACTIVE_V6" -eq 1 ]; then
				rule "-A $MGL_OUT_MARK -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
				mode_is "$IPV6_DNS_MODE" tproxy && emit_router_acl "$MGL_OUT_MARK" dns_tproxy
				case "$IPV6_TCP_MODE" in tproxy) emit_common_bypass "$MGL_OUT_MARK" "-p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_router_acl "$MGL_OUT_MARK" tcp_tproxy ;; esac
				case "$IPV6_UDP_MODE" in tproxy) emit_common_bypass "$MGL_OUT_MARK" "-p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_router_acl "$MGL_OUT_MARK" udp_tproxy ;; esac
			fi
			if [ "$TUN_ACTIVE_V6" -eq 1 ]; then
				rule "-A $MGL_OUT_TUN -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
				mode_is "$IPV6_DNS_MODE" tun && emit_router_acl "$MGL_OUT_TUN" dns_tun
				case "$IPV6_TCP_MODE" in tun) emit_common_bypass "$MGL_OUT_TUN" "-p tcp"; normalize_port_tokens "$PROXY_TCP_DPORT"; emit_router_acl "$MGL_OUT_TUN" tcp_tun ;; esac
				case "$IPV6_UDP_MODE" in tun) emit_common_bypass "$MGL_OUT_TUN" "-p udp"; normalize_port_tokens "$PROXY_UDP_DPORT"; emit_router_acl "$MGL_OUT_TUN" udp_tun ;; esac
			fi
		fi
	fi
	rule COMMIT
	emit_tun_filter_table
}

generate_family_rules() { case "$1" in 4) generate_ipv4_rules ;; 6) generate_ipv6_rules ;; *) return 1 ;; esac; }

load_config() {
	config_load nikki
	config_get_bool PROXY_ENABLED proxy enabled 0
	config_get IPV4_TCP_MODE proxy ipv4_tcp_mode
	config_get IPV4_UDP_MODE proxy ipv4_udp_mode
	config_get IPV6_TCP_MODE proxy ipv6_tcp_mode
	config_get IPV6_UDP_MODE proxy ipv6_udp_mode
	config_get IPV4_DNS_MODE proxy ipv4_dns_mode
	config_get IPV6_DNS_MODE proxy ipv6_dns_mode

	# Backward-compatible read for v1-v3 configurations.
	if [ -z "$IPV4_TCP_MODE$IPV4_UDP_MODE$IPV6_TCP_MODE$IPV6_UDP_MODE$IPV4_DNS_MODE$IPV6_DNS_MODE" ]; then
		local old_tcp old_udp old_v4 old_v6 old_dns4 old_dns6
		config_get old_tcp proxy tcp_mode redirect; config_get old_udp proxy udp_mode tproxy
		config_get_bool old_v4 proxy ipv4_proxy 1; config_get_bool old_v6 proxy ipv6_proxy 0
		config_get_bool old_dns4 proxy ipv4_dns_hijack 1; config_get_bool old_dns6 proxy ipv6_dns_hijack 0
		[ "$old_v4" -eq 1 ] && IPV4_TCP_MODE="$old_tcp" || IPV4_TCP_MODE=disable
		[ "$old_v4" -eq 1 ] && IPV4_UDP_MODE="$old_udp" || IPV4_UDP_MODE=disable
		[ "$old_v6" -eq 1 ] && IPV6_TCP_MODE="$old_tcp" || IPV6_TCP_MODE=disable
		[ "$old_v6" -eq 1 ] && IPV6_UDP_MODE="$old_udp" || IPV6_UDP_MODE=disable
		[ "$old_dns4" -eq 1 ] && IPV4_DNS_MODE=redirect || IPV4_DNS_MODE=disable
		[ "$old_dns6" -eq 1 ] && IPV6_DNS_MODE=redirect || IPV6_DNS_MODE=disable
	fi
	: "${IPV4_TCP_MODE:=disable}"; : "${IPV4_UDP_MODE:=disable}"; : "${IPV6_TCP_MODE:=disable}"; : "${IPV6_UDP_MODE:=disable}"; : "${IPV4_DNS_MODE:=disable}"; : "${IPV6_DNS_MODE:=disable}"

	config_get_bool ROUTER_PROXY proxy router_proxy 1
	config_get_bool LAN_PROXY_ENABLED proxy lan_proxy 1
	config_get_bool BYPASS_CHINA_V4 proxy bypass_china_mainland_ip 0
	config_get_bool BYPASS_CHINA_V6 proxy bypass_china_mainland_ip6 0
	config_get PROXY_TCP_DPORT proxy proxy_tcp_dport 0-65535
	config_get PROXY_UDP_DPORT proxy proxy_udp_dport 0-65535
	config_get TPROXY_MARK routing tproxy_fw_mark 0x80
	config_get TPROXY_MASK routing tproxy_fw_mask 0xFF
	config_get TUN_MARK routing tun_fw_mark 0x81
	config_get TUN_MASK routing tun_fw_mask 0xFF
	config_get CORE_MARK routing core_fw_mark 0x82
	config_get CORE_MASK routing core_fw_mask 0xFF

	TPROXY_ACTIVE_V4=0; TPROXY_ACTIVE_V6=0; TUN_ACTIVE_V4=0; TUN_ACTIVE_V6=0
	# Avoid shell &&/|| precedence ambiguity.
	if mode_is "$IPV4_TCP_MODE" tproxy || mode_is "$IPV4_UDP_MODE" tproxy || mode_is "$IPV4_DNS_MODE" tproxy; then TPROXY_ACTIVE_V4=1; fi
	if mode_is "$IPV6_TCP_MODE" tproxy || mode_is "$IPV6_UDP_MODE" tproxy || mode_is "$IPV6_DNS_MODE" tproxy; then TPROXY_ACTIVE_V6=1; fi
	if mode_is "$IPV4_TCP_MODE" tun || mode_is "$IPV4_UDP_MODE" tun || mode_is "$IPV4_DNS_MODE" tun; then TUN_ACTIVE_V4=1; fi
	if mode_is "$IPV6_TCP_MODE" tun || mode_is "$IPV6_UDP_MODE" tun || mode_is "$IPV6_DNS_MODE" tun; then TUN_ACTIVE_V6=1; fi
	LAN_DEVICES=""; config_list_foreach proxy lan_inbound_interface _add_lan_device
}

family_enabled() {
	case "$1" in
		4) mode_active "$IPV4_TCP_MODE" || mode_active "$IPV4_UDP_MODE" || mode_active "$IPV4_DNS_MODE" ;;
		6) mode_active "$IPV6_TCP_MODE" || mode_active "$IPV6_UDP_MODE" || mode_active "$IPV6_DNS_MODE" ;;
	esac
}

validate_modes() {
	case "$IPV4_TCP_MODE" in disable|redirect|tproxy|tun) ;; *) return 1 ;; esac
	case "$IPV4_UDP_MODE" in disable|tproxy|tun) ;; *) return 1 ;; esac
	case "$IPV6_TCP_MODE" in disable|redirect|tproxy|tun) ;; *) return 1 ;; esac
	case "$IPV6_UDP_MODE" in disable|tproxy|tun) ;; *) return 1 ;; esac
	case "$IPV4_DNS_MODE" in disable|redirect|tproxy|tun) ;; *) return 1 ;; esac
	case "$IPV6_DNS_MODE" in disable|redirect|tproxy|tun) ;; *) return 1 ;; esac
}

check_family_backend() {
	local family="$1" cmd restore
	case "$family" in 4) cmd="$IPT4"; restore="$IPT4_RESTORE" ;; 6) cmd="$IPT6"; restore="$IPT6_RESTORE" ;; *) return 1 ;; esac
	family_enabled "$family" || return 0
	command_exists "$cmd" && command_exists "$restore" || return 1
	"$cmd" -m owner -h >/dev/null 2>&1 || return 1
	"$cmd" -m set -h >/dev/null 2>&1 || return 1
	if [ "$family" = 4 ]; then
		if mode_is "$IPV4_TCP_MODE" redirect || mode_is "$IPV4_DNS_MODE" redirect; then
			"$cmd" -t nat -j REDIRECT -h >/dev/null 2>&1 || return 1
		fi
		if [ "$TPROXY_ACTIVE_V4" -eq 1 ]; then
			"$cmd" -t mangle -j TPROXY -h >/dev/null 2>&1 || return 1
		fi
		if [ "$TUN_ACTIVE_V4" -eq 1 ]; then
			"$cmd" -t mangle -j MARK -h >/dev/null 2>&1 || return 1
		fi
	else
		if mode_is "$IPV6_TCP_MODE" redirect || mode_is "$IPV6_DNS_MODE" redirect; then
			"$cmd" -t nat -j REDIRECT -h >/dev/null 2>&1 || return 1
		fi
		if [ "$TPROXY_ACTIVE_V6" -eq 1 ]; then
			"$cmd" -t mangle -j TPROXY -h >/dev/null 2>&1 || return 1
		fi
		if [ "$TUN_ACTIVE_V6" -eq 1 ]; then
			"$cmd" -t mangle -j MARK -h >/dev/null 2>&1 || return 1
		fi
	fi
	return 0
}

apply_rules() {
	acquire_lock || return 1
	prepare_files; load_config
	[ "$PROXY_ENABLED" -eq 1 ] || { remove_rules_only; release_lock; return 0; }
	validate_modes || { log "Firewall" "Invalid legacy proxy mode."; release_lock; return 1; }
	if ! family_enabled 4 && ! family_enabled 6; then remove_rules_only; release_lock; return 0; fi
	[ -r "$RUN_PROFILE_PATH" ] || { log "Firewall" "Runtime profile is missing."; release_lock; return 1; }
	load_runtime_endpoints || { log "Firewall" "Unable to determine a required Mihomo listener or TUN device."; release_lock; return 1; }
	check_family_backend 4 || { log "Firewall" "Required IPv4 iptables extensions are unavailable."; release_lock; return 1; }
	check_family_backend 6 || { log "Firewall" "Required IPv6 ip6tables extensions are unavailable."; release_lock; return 1; }
	prepare_ipsets || { log "Firewall" "Failed to prepare IPv4/IPv6 ipsets."; release_lock; return 1; }
	remove_rules_only
	if family_enabled 4; then generate_family_rules 4; "$IPT4_RESTORE" --noflush < "$RULES_FILE_V4" || { log "Firewall" "iptables-restore failed; removing partial rules."; remove_rules_only; release_lock; return 1; }; fi
	if family_enabled 6; then generate_family_rules 6; "$IPT6_RESTORE" --noflush < "$RULES_FILE_V6" || { log "Firewall" "ip6tables-restore failed; removing partial rules."; remove_rules_only; release_lock; return 1; }; fi
	log "Firewall" "IPv4/IPv6 xtables rules applied."
	release_lock
}

render_rules() {
	prepare_files; load_config; validate_modes || return 1
	[ -r "$RUN_PROFILE_PATH" ] || return 1
	load_runtime_endpoints || return 1
	if family_enabled 4; then generate_family_rules 4; printf '# IPv4 / iptables-restore\n'; cat "$RULES_FILE_V4"; fi
	if family_enabled 6; then generate_family_rules 6; printf '# IPv6 / ip6tables-restore\n'; cat "$RULES_FILE_V6"; fi
}
check_backend() { load_config; validate_modes || return 1; command_exists "$IPSET" || return 1; check_family_backend 4 && check_family_backend 6; }

prepare_files
case "${1:-apply}" in
	apply|reload) apply_rules ;;
	remove|stop) remove_all ;;
	check) check_backend ;;
	render) render_rules ;;
	*) echo "Usage: $0 {apply|reload|remove|check|render}" >&2; exit 2 ;;
esac
