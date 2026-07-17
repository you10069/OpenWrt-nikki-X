#!/bin/sh

# Nikki legacy firewall3/xtables backend.
# Supported data plane: IPv4 + IPv6, TCP REDIRECT, UDP TPROXY,
# router/LAN DNS hijack and access control.

. /lib/functions.sh
. /etc/nikki/scripts/include.sh

IPT4="${IPT4:-iptables}"
IPT6="${IPT6:-ip6tables}"
IPT4_RESTORE="${IPT4_RESTORE:-iptables-restore}"
IPT6_RESTORE="${IPT6_RESTORE:-ip6tables-restore}"
IPSET="${IPSET:-ipset}"
LOCK_DIR="${LOCK_DIR:-/var/lock/nikki-fw3.lock}"
RULES_FILE_V4="$TEMP_DIR/iptables-v4.rules"
RULES_FILE_V6="$TEMP_DIR/iptables-v6.rules"
IPSET_FILE="$TEMP_DIR/ipset.rules"
CHINA_IP4_FILE="${CHINA_IP4_FILE:-/etc/nikki/ipset/geoip_cn.txt}"
CHINA_IP6_FILE="${CHINA_IP6_FILE:-/etc/nikki/ipset/geoip6_cn.txt}"

# Agreed short and explicit chain names.
NAT_PRE_DNS_V4="NIK_NAT_PRE_DNS_V4"
NAT_PRE_TCP_V4="NIK_NAT_PRE_TCP_V4"
NAT_OUT_DNS_V4="NIK_NAT_OUT_DNS_V4"
NAT_OUT_TCP_V4="NIK_NAT_OUT_TCP_V4"
MGL_PRE_CTRL_V4="NIK_MGL_PRE_CTRL_V4"
MGL_PRE_TPROXY_V4="NIK_MGL_PRE_TPROXY_V4"
MGL_OUT_MARK_V4="NIK_MGL_OUT_MARK_V4"

NAT_PRE_DNS_V6="NIK_NAT_PRE_DNS_V6"
NAT_PRE_TCP_V6="NIK_NAT_PRE_TCP_V6"
NAT_OUT_DNS_V6="NIK_NAT_OUT_DNS_V6"
NAT_OUT_TCP_V6="NIK_NAT_OUT_TCP_V6"
MGL_PRE_CTRL_V6="NIK_MGL_PRE_CTRL_V6"
MGL_PRE_TPROXY_V6="NIK_MGL_PRE_TPROXY_V6"
MGL_OUT_MARK_V6="NIK_MGL_OUT_MARK_V6"

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

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

_LIST_COUNT=0
_count_list_item() {
	_LIST_COUNT=$((_LIST_COUNT + 1))
}

list_count() {
	_LIST_COUNT=0
	config_list_foreach "$1" "$2" _count_list_item
	echo "$_LIST_COUNT"
}

valid_port() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

extract_listen_port() {
	# Handles 0.0.0.0:1053, :1053, [::]:1053 and plain 1053.
	printf '%s\n' "$1" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p; t; /^[0-9][0-9]*$/p'
}

dns_listener_supports_ipv6() {
	case "$1" in
		\[*\]:[0-9]*|:[0-9]*|[0-9]*) return 0 ;;
		*) return 1 ;;
	esac
}

# Resolve only listeners required by enabled address families and modes.
load_ports() {
	local redirect_listener tproxy_listener dns_listen
	REDIR_PORT=''
	TPROXY_PORT=''
	DNS_PORT=''
	DNS_LISTEN=''
	config_get redirect_listener core redirect_listener_name redir-in
	config_get tproxy_listener core tproxy_listener_name tproxy-in

	if { [ "$IPV4_PROXY" -eq 1 ] || [ "$IPV6_PROXY" -eq 1 ]; } && [ "$TCP_MODE" = redirect ]; then
		REDIR_PORT="$(REDIRECT_LISTENER="$redirect_listener" yq -M -r '."redir-port" // (.listeners[]? | select(.name == env(REDIRECT_LISTENER) and .type == "redir") | .port) // ""' "$RUN_PROFILE_PATH" 2>/dev/null)"
		valid_port "$REDIR_PORT" || return 1
	fi

	if { [ "$IPV4_PROXY" -eq 1 ] || [ "$IPV6_PROXY" -eq 1 ]; } && [ "$UDP_MODE" = tproxy ]; then
		TPROXY_PORT="$(TPROXY_LISTENER="$tproxy_listener" yq -M -r '."tproxy-port" // (.listeners[]? | select(.name == env(TPROXY_LISTENER) and .type == "tproxy") | .port) // ""' "$RUN_PROFILE_PATH" 2>/dev/null)"
		valid_port "$TPROXY_PORT" || return 1
	fi

	if [ "$IPV4_DNS_HIJACK" -eq 1 ] || [ "$IPV6_DNS_HIJACK" -eq 1 ]; then
		dns_listen="$(yq -M -r '.dns.listen // ""' "$RUN_PROFILE_PATH" 2>/dev/null)"
		DNS_LISTEN="$dns_listen"
		DNS_PORT="$(extract_listen_port "$dns_listen")"
		valid_port "$DNS_PORT" || return 1
		if [ "$IPV6_DNS_HIJACK" -eq 1 ] && ! dns_listener_supports_ipv6 "$dns_listen"; then
			log "Firewall" "IPv6 DNS hijack requires an IPv6-capable DNS listen address (for example [::]:1053)."
			return 1
		fi
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
	case " $LAN_DEVICES " in
		*" $device "*) ;;
		*) LAN_DEVICES="$LAN_DEVICES $device" ;;
	esac
}

valid_ipv4_or_cidr() {
	printf '%s\n' "$1" | awk -F/ '
		BEGIN { ok = 1 }
		NF < 1 || NF > 2 { ok = 0; exit }
		NF == 2 && ($2 !~ /^[0-9]+$/ || $2 < 0 || $2 > 32) { ok = 0; exit }
		{
			n = split($1, oct, ".")
			if (n != 4) { ok = 0; exit }
			for (i = 1; i <= 4; i++) {
				if (oct[i] !~ /^[0-9]+$/ || oct[i] < 0 || oct[i] > 255) {
					ok = 0
					exit
				}
			}
		}
		END { exit(ok && NR == 1 ? 0 : 1) }
	'
}

valid_ipv6_or_cidr() {
	local value="$1" address prefix
	case "$value" in
		''|*[!0-9a-fA-F:./]*) return 1 ;;
	esac
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

	_add_reserved_ip4() {
		valid_ipv4_or_cidr "$1" && printf 'add %s %s -exist\n' "$SET_RESERVED_V4_TMP" "$1" >> "$IPSET_FILE"
	}
	config_list_foreach proxy reserved_ip _add_reserved_ip4
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_RESERVED_V4_TMP $SET_RESERVED_V4
	destroy $SET_RESERVED_V4_TMP
	create $SET_CHINA_V4 hash:net family inet hashsize 4096 maxelem 65536 -exist
	create $SET_CHINA_V4_TMP hash:net family inet hashsize 4096 maxelem 65536 -exist
	flush $SET_CHINA_V4_TMP
	EOF_IPSET
	if [ "$BYPASS_CHINA_V4" -eq 1 ] && [ -r "$CHINA_IP4_FILE" ]; then
		awk -v set="$SET_CHINA_V4_TMP" 'NF && $1 !~ /^#/ { print "add " set " " $1 " -exist" }' "$CHINA_IP4_FILE" >> "$IPSET_FILE"
	fi
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_CHINA_V4_TMP $SET_CHINA_V4
	destroy $SET_CHINA_V4_TMP
	create $SET_RESERVED_V6 hash:net family inet6 hashsize 128 maxelem 1024 -exist
	create $SET_RESERVED_V6_TMP hash:net family inet6 hashsize 128 maxelem 1024 -exist
	flush $SET_RESERVED_V6_TMP
	EOF_IPSET

	_add_reserved_ip6() {
		valid_ipv6_or_cidr "$1" && printf 'add %s %s -exist\n' "$SET_RESERVED_V6_TMP" "$1" >> "$IPSET_FILE"
	}
	config_list_foreach proxy reserved_ip6 _add_reserved_ip6
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_RESERVED_V6_TMP $SET_RESERVED_V6
	destroy $SET_RESERVED_V6_TMP
	create $SET_CHINA_V6 hash:net family inet6 hashsize 4096 maxelem 65536 -exist
	create $SET_CHINA_V6_TMP hash:net family inet6 hashsize 4096 maxelem 65536 -exist
	flush $SET_CHINA_V6_TMP
	EOF_IPSET
	if [ "$BYPASS_CHINA_V6" -eq 1 ] && [ -r "$CHINA_IP6_FILE" ]; then
		awk -v set="$SET_CHINA_V6_TMP" 'NF && $1 !~ /^#/ { print "add " set " " $1 " -exist" }' "$CHINA_IP6_FILE" >> "$IPSET_FILE"
	fi
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

remove_family_rules() {
	local cmd="$1" nat_pre_dns="$2" nat_pre_tcp="$3" nat_out_dns="$4" nat_out_tcp="$5" mgl_pre_ctrl="$6" mgl_pre_tproxy="$7" mgl_out_mark="$8"
	remove_jump "$cmd" nat PREROUTING "$nat_pre_dns"
	remove_jump "$cmd" nat PREROUTING "$nat_pre_tcp"
	remove_jump "$cmd" nat OUTPUT "$nat_out_dns"
	remove_jump "$cmd" nat OUTPUT "$nat_out_tcp"
	remove_jump "$cmd" mangle PREROUTING "$mgl_pre_ctrl"
	remove_jump "$cmd" mangle OUTPUT "$mgl_out_mark"

	remove_chain "$cmd" nat "$nat_pre_dns"
	remove_chain "$cmd" nat "$nat_pre_tcp"
	remove_chain "$cmd" nat "$nat_out_dns"
	remove_chain "$cmd" nat "$nat_out_tcp"
	remove_chain "$cmd" mangle "$mgl_pre_ctrl"
	remove_chain "$cmd" mangle "$mgl_pre_tproxy"
	remove_chain "$cmd" mangle "$mgl_out_mark"
}

remove_rules_only() {
	remove_family_rules "$IPT4" "$NAT_PRE_DNS_V4" "$NAT_PRE_TCP_V4" "$NAT_OUT_DNS_V4" "$NAT_OUT_TCP_V4" "$MGL_PRE_CTRL_V4" "$MGL_PRE_TPROXY_V4" "$MGL_OUT_MARK_V4"
	remove_family_rules "$IPT6" "$NAT_PRE_DNS_V6" "$NAT_PRE_TCP_V6" "$NAT_OUT_DNS_V6" "$NAT_OUT_TCP_V6" "$MGL_PRE_CTRL_V6" "$MGL_PRE_TPROXY_V6" "$MGL_OUT_MARK_V6"
}

remove_all() {
	acquire_lock || return 1
	remove_rules_only
	for set_name in \
		"$SET_RESERVED_V4" "$SET_RESERVED_V4_TMP" "$SET_CHINA_V4" "$SET_CHINA_V4_TMP" \
		"$SET_RESERVED_V6" "$SET_RESERVED_V6_TMP" "$SET_CHINA_V6" "$SET_CHINA_V6_TMP"; do
		$IPSET destroy "$set_name" >/dev/null 2>&1
	done
	release_lock
}

rule() {
	printf '%s\n' "$*" >> "$RULES_FILE"
}

normalize_port_tokens() {
	local input="$1" token count=0 chunk="" first last normalized
	PORT_ALL=0
	PORT_CHUNKS=""
	[ -n "$input" ] || input="0-65535"
	input="$(printf '%s' "$input" | tr ',' ' ')"
	for token in $input; do
		case "$token" in
			0-65535|0:65535)
				PORT_ALL=1
				PORT_CHUNKS=""
				return 0
				;;
		esac
		if printf '%s\n' "$token" | grep -Eq '^[0-9]+$'; then
			valid_port "$token" || continue
			normalized="$token"
		elif printf '%s\n' "$token" | grep -Eq '^[0-9]+[-:][0-9]+$'; then
			first="${token%%[-:]*}"
			last="${token#*[-:]}"
			valid_port "$first" && valid_port "$last" && [ "$first" -le "$last" ] || continue
			normalized="$first:$last"
		else
			continue
		fi
		if [ -z "$chunk" ]; then chunk="$normalized"; else chunk="$chunk,$normalized"; fi
		count=$((count + 1))
		if [ "$count" -eq 15 ]; then
			PORT_CHUNKS="${PORT_CHUNKS}${PORT_CHUNKS:+
}${chunk}"
			chunk=""
			count=0
		fi
	done
	[ -z "$chunk" ] || PORT_CHUNKS="${PORT_CHUNKS}${PORT_CHUNKS:+
}${chunk}"
	[ -n "$PORT_CHUNKS" ] || PORT_ALL=1
}

emit_port_action() {
	local chain="$1" base="$2" target="$3" chunk oldifs
	if [ "$PORT_ALL" -eq 1 ]; then
		rule "-A $chain $base $target"
		return
	fi
	oldifs="$IFS"; IFS='
'
	for chunk in $PORT_CHUNKS; do
		[ -n "$chunk" ] && rule "-A $chain $base -m multiport --dports $chunk $target"
	done
	IFS="$oldifs"
}

emit_dscp_bypass() {
	local chain="$1" base="$2" value
	_emit_dscp() {
		value="$1"
		case "$value" in ''|*[!0-9]*) return ;; esac
		[ "$value" -le 63 ] && rule "-A $chain $base -m dscp --dscp $value -j RETURN"
	}
	config_list_foreach proxy bypass_dscp _emit_dscp
}

emit_fwmark_bypass() {
	local chain="$1" base="$2" value mark mask
	_emit_fwmark() {
		value="$1"
		mark="${value%%/*}"
		[ "$mark" = "$value" ] && mask="0xFFFFFFFF" || mask="${value#*/}"
		case "$mark/$mask" in
			*[!0-9a-fA-FxX/]*|/) return ;;
		esac
		rule "-A $chain $base -m mark --mark $mark/$mask -j RETURN"
	}
	config_list_foreach proxy bypass_fwmark _emit_fwmark
}

emit_common_bypass() {
	local chain="$1" base="$2"
	rule "-A $chain $base -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
	rule "-A $chain $base -m addrtype --dst-type LOCAL -j RETURN"
	rule "-A $chain $base -m set --match-set $SET_RESERVED dst -j RETURN"
	[ "$BYPASS_CHINA" -eq 1 ] && rule "-A $chain $base -m set --match-set $SET_CHINA dst -j RETURN"
	emit_dscp_bypass "$chain" "$base"
	emit_fwmark_bypass "$chain" "$base"
}

user_exists() {
	grep -q "^$1:" /etc/passwd 2>/dev/null
}

group_exists() {
	grep -q "^$1:" /etc/group 2>/dev/null
}

LAN_CHAIN=""
LAN_BASE=""
LAN_KIND=""
LAN_DNS_PORT=""
LAN_IP_OPTION=""
LAN_VALIDATE_FN=""
LAN_DNS=0
LAN_ACL_PROXY=0

_emit_lan_proxy_target() {
	local selector="$1" dns="$2" proxy="$3" base
	base="$LAN_BASE $selector"
	case "$LAN_KIND" in
		dns)
			if [ "$dns" -eq 1 ]; then
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j REDIRECT --to-ports $LAN_DNS_PORT"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j REDIRECT --to-ports $LAN_DNS_PORT"
			else
				rule "-A $LAN_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $LAN_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi
			;;
		tcp)
			if [ "$proxy" -eq 1 ]; then
				emit_port_action "$LAN_CHAIN" "$base -p tcp" "-j REDIRECT --to-ports $REDIR_PORT"
				rule "-A $LAN_CHAIN $base -p tcp -j RETURN"
			else
				rule "-A $LAN_CHAIN $base -p tcp -j RETURN"
			fi
			;;
		udp)
			[ "$dns" -eq 1 ] && rule "-A $LAN_CHAIN $base -p udp --dport 53 -j RETURN"
			if [ "$proxy" -eq 1 ]; then
				emit_port_action "$LAN_CHAIN" "$base -p udp" "-j $MGL_PRE_TPROXY"
				rule "-A $LAN_CHAIN $base -p udp -j RETURN"
			else
				rule "-A $LAN_CHAIN $base -p udp -j RETURN"
			fi
			;;
	esac
}

_emit_lan_ip() {
	"$LAN_VALIDATE_FN" "$1" && _emit_lan_proxy_target "-s $1" "$LAN_DNS" "$LAN_ACL_PROXY"
}

_emit_lan_mac() {
	printf '%s' "$1" | grep -Eqi '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' && \
		_emit_lan_proxy_target "-m mac --mac-source $1" "$LAN_DNS" "$LAN_ACL_PROXY"
}

_emit_lan_acl_section() {
	local section="$1" enabled selector_count
	config_get_bool enabled "$section" enabled 0
	[ "$enabled" -eq 1 ] || return 0
	config_get_bool LAN_DNS "$section" dns 0
	config_get_bool LAN_ACL_PROXY "$section" proxy 0
	selector_count=$(( $(list_count "$section" ip) + $(list_count "$section" ip6) + $(list_count "$section" mac) ))
	config_list_foreach "$section" "$LAN_IP_OPTION" _emit_lan_ip
	config_list_foreach "$section" mac _emit_lan_mac
	[ "$selector_count" -eq 0 ] && _emit_lan_proxy_target "" "$LAN_DNS" "$LAN_ACL_PROXY"
}

emit_lan_acl() {
	LAN_CHAIN="$1"
	LAN_BASE="-i $2"
	LAN_KIND="$3"
	LAN_DNS_PORT="$DNS_PORT"
	config_foreach _emit_lan_acl_section lan_access_control
}

RTR_CHAIN=""
RTR_KIND=""
RTR_DNS=0
RTR_PROXY=0

_emit_router_target() {
	local selector="$1" base
	base="$selector"
	case "$RTR_KIND" in
		dns)
			if [ "$RTR_DNS" -eq 1 ]; then
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
			else
				rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
				rule "-A $RTR_CHAIN $base -p tcp --dport 53 -j RETURN"
			fi
			;;
		tcp)
			if [ "$RTR_PROXY" -eq 1 ]; then
				emit_port_action "$RTR_CHAIN" "$base -p tcp" "-j REDIRECT --to-ports $REDIR_PORT"
				rule "-A $RTR_CHAIN $base -p tcp -j RETURN"
			else
				rule "-A $RTR_CHAIN $base -p tcp -j RETURN"
			fi
			;;
		udp)
			[ "$RTR_DNS" -eq 1 ] && rule "-A $RTR_CHAIN $base -p udp --dport 53 -j RETURN"
			if [ "$RTR_PROXY" -eq 1 ]; then
				emit_port_action "$RTR_CHAIN" "$base -p udp" "-j MARK --set-xmark $TPROXY_MARK/$TPROXY_MASK"
				rule "-A $RTR_CHAIN $base -p udp -j RETURN"
			else
				rule "-A $RTR_CHAIN $base -p udp -j RETURN"
			fi
			;;
	esac
}

_emit_router_user() {
	user_exists "$1" || return 0
	RTR_HAS_SELECTOR=1
	_emit_router_target "-m owner --uid-owner $1"
}

_emit_router_group() {
	group_exists "$1" || return 0
	RTR_HAS_SELECTOR=1
	_emit_router_target "-m owner --gid-owner $1"
}

_emit_router_acl_section() {
	local section="$1" enabled unsupported_cgroup
	config_get_bool enabled "$section" enabled 0
	[ "$enabled" -eq 1 ] || return 0
	config_get_bool RTR_DNS "$section" dns 0
	config_get_bool RTR_PROXY "$section" proxy 0
	RTR_HAS_SELECTOR=0
	config_list_foreach "$section" user _emit_router_user
	config_list_foreach "$section" group _emit_router_group
	unsupported_cgroup="$(list_count "$section" cgroup)"
	if [ "$RTR_HAS_SELECTOR" -eq 0 ] && [ "$unsupported_cgroup" -eq 0 ]; then
		_emit_router_target ""
	fi
}

emit_router_acl() {
	RTR_CHAIN="$1"
	RTR_KIND="$2"
	config_foreach _emit_router_acl_section router_access_control
}

select_family_context() {
	case "$1" in
		4)
			RULES_FILE="$RULES_FILE_V4"
			NAT_PRE_DNS="$NAT_PRE_DNS_V4"; NAT_PRE_TCP="$NAT_PRE_TCP_V4"
			NAT_OUT_DNS="$NAT_OUT_DNS_V4"; NAT_OUT_TCP="$NAT_OUT_TCP_V4"
			MGL_PRE_CTRL="$MGL_PRE_CTRL_V4"; MGL_PRE_TPROXY="$MGL_PRE_TPROXY_V4"; MGL_OUT_MARK="$MGL_OUT_MARK_V4"
			SET_RESERVED="$SET_RESERVED_V4"; SET_CHINA="$SET_CHINA_V4"
			FAMILY_PROXY="$IPV4_PROXY"; FAMILY_DNS="$IPV4_DNS_HIJACK"; BYPASS_CHINA="$BYPASS_CHINA_V4"
			LAN_IP_OPTION="ip"; LAN_VALIDATE_FN="valid_ipv4_or_cidr"
			;;
		6)
			RULES_FILE="$RULES_FILE_V6"
			NAT_PRE_DNS="$NAT_PRE_DNS_V6"; NAT_PRE_TCP="$NAT_PRE_TCP_V6"
			NAT_OUT_DNS="$NAT_OUT_DNS_V6"; NAT_OUT_TCP="$NAT_OUT_TCP_V6"
			MGL_PRE_CTRL="$MGL_PRE_CTRL_V6"; MGL_PRE_TPROXY="$MGL_PRE_TPROXY_V6"; MGL_OUT_MARK="$MGL_OUT_MARK_V6"
			SET_RESERVED="$SET_RESERVED_V6"; SET_CHINA="$SET_CHINA_V6"
			FAMILY_PROXY="$IPV6_PROXY"; FAMILY_DNS="$IPV6_DNS_HIJACK"; BYPASS_CHINA="$BYPASS_CHINA_V6"
			LAN_IP_OPTION="ip6"; LAN_VALIDATE_FN="valid_ipv6_or_cidr"
			;;
		*) return 1 ;;
	esac
}

generate_family_rules() {
	select_family_context "$1" || return 1
	: > "$RULES_FILE"
	cat >> "$RULES_FILE" <<-EOF_RULES
	*nat
	:$NAT_PRE_DNS - [0:0]
	:$NAT_PRE_TCP - [0:0]
	:$NAT_OUT_DNS - [0:0]
	:$NAT_OUT_TCP - [0:0]
	EOF_RULES

	# Every -I ... 1 becomes the new first rule. Emit TCP first and DNS second
	# so DNS stays ahead of broad TCP REDIRECT in the installed chain.
	[ "$LAN_PROXY_ENABLED" -eq 1 ] && [ "$FAMILY_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ] && rule "-I PREROUTING 1 -j $NAT_PRE_TCP"
	[ "$LAN_PROXY_ENABLED" -eq 1 ] && [ "$FAMILY_DNS" -eq 1 ] && rule "-I PREROUTING 1 -j $NAT_PRE_DNS"
	[ "$ROUTER_PROXY" -eq 1 ] && [ "$FAMILY_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ] && rule "-I OUTPUT 1 -j $NAT_OUT_TCP"
	[ "$ROUTER_PROXY" -eq 1 ] && [ "$FAMILY_DNS" -eq 1 ] && rule "-I OUTPUT 1 -j $NAT_OUT_DNS"

	if [ "$LAN_PROXY_ENABLED" -eq 1 ]; then
		for dev in $LAN_DEVICES; do
			[ "$FAMILY_DNS" -eq 1 ] && emit_lan_acl "$NAT_PRE_DNS" "$dev" dns
			if [ "$FAMILY_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ]; then
				emit_common_bypass "$NAT_PRE_TCP" "-i $dev -p tcp"
				normalize_port_tokens "$PROXY_TCP_DPORT"
				emit_lan_acl "$NAT_PRE_TCP" "$dev" tcp
			fi
		done
	fi

	if [ "$ROUTER_PROXY" -eq 1 ]; then
		if [ "$FAMILY_DNS" -eq 1 ]; then
			rule "-A $NAT_OUT_DNS -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
			emit_router_acl "$NAT_OUT_DNS" dns
		fi
		if [ "$FAMILY_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ]; then
			emit_common_bypass "$NAT_OUT_TCP" "-p tcp"
			normalize_port_tokens "$PROXY_TCP_DPORT"
			emit_router_acl "$NAT_OUT_TCP" tcp
		fi
	fi
	rule COMMIT

	cat >> "$RULES_FILE" <<-EOF_RULES
	*mangle
	:$MGL_PRE_CTRL - [0:0]
	:$MGL_PRE_TPROXY - [0:0]
	:$MGL_OUT_MARK - [0:0]
	EOF_RULES

	if [ "$FAMILY_PROXY" -eq 1 ] && [ "$UDP_MODE" = tproxy ]; then
		rule "-I PREROUTING 1 -j $MGL_PRE_CTRL"
		[ "$ROUTER_PROXY" -eq 1 ] && rule "-I OUTPUT 1 -j $MGL_OUT_MARK"
		rule "-A $MGL_PRE_TPROXY -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $TPROXY_MARK/$TPROXY_MASK"
		[ "$ROUTER_PROXY" -eq 1 ] && rule "-A $MGL_PRE_CTRL -i lo -p udp -m mark --mark $TPROXY_MARK/$TPROXY_MASK -j $MGL_PRE_TPROXY"

		if [ "$LAN_PROXY_ENABLED" -eq 1 ]; then
			for dev in $LAN_DEVICES; do
				emit_common_bypass "$MGL_PRE_CTRL" "-i $dev -p udp"
				normalize_port_tokens "$PROXY_UDP_DPORT"
				emit_lan_acl "$MGL_PRE_CTRL" "$dev" udp
			done
		fi

		if [ "$ROUTER_PROXY" -eq 1 ]; then
			emit_common_bypass "$MGL_OUT_MARK" "-p udp"
			normalize_port_tokens "$PROXY_UDP_DPORT"
			emit_router_acl "$MGL_OUT_MARK" udp
		fi
	fi
	rule COMMIT
}

load_config() {
	config_load nikki
	config_get_bool PROXY_ENABLED proxy enabled 0
	config_get TCP_MODE proxy tcp_mode redirect
	config_get UDP_MODE proxy udp_mode tproxy
	config_get_bool IPV4_PROXY proxy ipv4_proxy 1
	config_get_bool IPV6_PROXY proxy ipv6_proxy 0
	config_get_bool IPV4_DNS_HIJACK proxy ipv4_dns_hijack 1
	config_get_bool IPV6_DNS_HIJACK proxy ipv6_dns_hijack 0
	config_get_bool ROUTER_PROXY proxy router_proxy 1
	config_get_bool LAN_PROXY_ENABLED proxy lan_proxy 1
	config_get_bool BYPASS_CHINA_V4 proxy bypass_china_mainland_ip 0
	config_get_bool BYPASS_CHINA_V6 proxy bypass_china_mainland_ip6 0
	config_get PROXY_TCP_DPORT proxy proxy_tcp_dport 0-65535
	config_get PROXY_UDP_DPORT proxy proxy_udp_dport 0-65535

	config_get TPROXY_MARK routing tproxy_fw_mark 0x80
	config_get TPROXY_MASK routing tproxy_fw_mask 0xFF
	config_get CORE_MARK routing core_fw_mark 0x82
	config_get CORE_MASK routing core_fw_mask 0xFF

	LAN_DEVICES=""
	config_list_foreach proxy lan_inbound_interface _add_lan_device
}

family_enabled() {
	case "$1" in
		4) [ "$IPV4_PROXY" -eq 1 ] || [ "$IPV4_DNS_HIJACK" -eq 1 ] ;;
		6) [ "$IPV6_PROXY" -eq 1 ] || [ "$IPV6_DNS_HIJACK" -eq 1 ] ;;
	esac
}

check_family_backend() {
	local family="$1" cmd restore proxy dns
	case "$family" in
		4) cmd="$IPT4"; restore="$IPT4_RESTORE"; proxy="$IPV4_PROXY"; dns="$IPV4_DNS_HIJACK" ;;
		6) cmd="$IPT6"; restore="$IPT6_RESTORE"; proxy="$IPV6_PROXY"; dns="$IPV6_DNS_HIJACK" ;;
		*) return 1 ;;
	esac
	[ "$proxy" -eq 1 ] || [ "$dns" -eq 1 ] || return 0
	command_exists "$cmd" || return 1
	command_exists "$restore" || return 1
	"$cmd" -m owner -h >/dev/null 2>&1 || return 1
	"$cmd" -m set -h >/dev/null 2>&1 || return 1
	if [ "$proxy" -eq 1 ] && [ "$UDP_MODE" = tproxy ]; then
		"$cmd" -t mangle -j TPROXY -h >/dev/null 2>&1 || return 1
	fi
	if [ "$dns" -eq 1 ] || { [ "$proxy" -eq 1 ] && [ "$TCP_MODE" = redirect ]; }; then
		"$cmd" -t nat -j REDIRECT -h >/dev/null 2>&1 || return 1
	fi
	return 0
}

apply_rules() {
	acquire_lock || return 1
	prepare_files
	load_config

	[ "$PROXY_ENABLED" -eq 1 ] || {
		remove_rules_only
		release_lock
		return 0
	}
	if ! family_enabled 4 && ! family_enabled 6; then
		remove_rules_only
		release_lock
		return 0
	fi
	[ "$TCP_MODE" = redirect ] || [ -z "$TCP_MODE" ] || {
		log "Firewall" "Unsupported legacy TCP mode: $TCP_MODE."
		release_lock
		return 1
	}
	[ "$UDP_MODE" = tproxy ] || [ -z "$UDP_MODE" ] || {
		log "Firewall" "Unsupported legacy UDP mode: $UDP_MODE."
		release_lock
		return 1
	}
	[ -r "$RUN_PROFILE_PATH" ] || {
		log "Firewall" "Runtime profile is missing."
		release_lock
		return 1
	}
	load_ports || {
		log "Firewall" "Unable to determine a required Mihomo listener port."
		release_lock
		return 1
	}
	check_family_backend 4 || {
		log "Firewall" "Required IPv4 iptables extensions are unavailable."
		release_lock
		return 1
	}
	check_family_backend 6 || {
		log "Firewall" "Required IPv6 ip6tables extensions are unavailable."
		release_lock
		return 1
	}

	if [ "$IPV4_PROXY" -eq 1 ] || [ "$IPV6_PROXY" -eq 1 ]; then
		prepare_ipsets || {
			log "Firewall" "Failed to prepare IPv4/IPv6 ipsets."
			release_lock
			return 1
		}
	fi
	remove_rules_only

	if family_enabled 4; then
		generate_family_rules 4
		if ! "$IPT4_RESTORE" --noflush < "$RULES_FILE_V4"; then
			log "Firewall" "iptables-restore failed; removing partial rules."
			remove_rules_only
			release_lock
			return 1
		fi
	fi
	if family_enabled 6; then
		generate_family_rules 6
		if ! "$IPT6_RESTORE" --noflush < "$RULES_FILE_V6"; then
			log "Firewall" "ip6tables-restore failed; removing partial rules."
			remove_rules_only
			release_lock
			return 1
		fi
	fi

	log "Firewall" "IPv4/IPv6 xtables rules applied."
	release_lock
	return 0
}

render_rules() {
	prepare_files
	load_config
	[ -r "$RUN_PROFILE_PATH" ] || return 1
	load_ports || return 1
	if family_enabled 4; then
		generate_family_rules 4
		printf '# IPv4 / iptables-restore\n'
		cat "$RULES_FILE_V4"
	fi
	if family_enabled 6; then
		generate_family_rules 6
		printf '# IPv6 / ip6tables-restore\n'
		cat "$RULES_FILE_V6"
	fi
}

check_backend() {
	load_config
	command_exists "$IPSET" || return 1
	check_family_backend 4 || return 1
	check_family_backend 6 || return 1
	return 0
}

prepare_files

case "${1:-apply}" in
	apply|reload)
		apply_rules
		;;
	remove|stop)
		remove_all
		;;
	check)
		check_backend
		;;
	render)
		render_rules
		;;
	*)
		echo "Usage: $0 {apply|reload|remove|check|render}" >&2
		exit 2
		;;
esac
