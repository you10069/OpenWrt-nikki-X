#!/bin/sh

# Nikki legacy firewall3/iptables backend.
# First release scope: IPv4, TCP REDIRECT, UDP TPROXY, router + LAN DNS hijack.

. /lib/functions.sh
. /etc/nikki/scripts/include.sh

IPT="${IPT:-iptables}"
IPSET="${IPSET:-ipset}"
LOCK_DIR="/var/lock/nikki-fw3.lock"
RULES_FILE="$TEMP_DIR/iptables.rules"
IPSET_FILE="$TEMP_DIR/ipset.rules"
CHINA_IP_FILE="/etc/nikki/ipset/geoip_cn.txt"

# Agreed short and explicit chain names.
NAT_PRE_DNS="NIK_NAT_PRE_DNS_V4"
NAT_PRE_TCP="NIK_NAT_PRE_TCP_V4"
NAT_OUT_DNS="NIK_NAT_OUT_DNS_V4"
NAT_OUT_TCP="NIK_NAT_OUT_TCP_V4"
MGL_PRE_CTRL="NIK_MGL_PRE_CTRL_V4"
MGL_PRE_TPROXY="NIK_MGL_PRE_TPROXY_V4"
MGL_OUT_MARK="NIK_MGL_OUT_MARK_V4"

SET_RESERVED="nik_reserved_v4"
SET_RESERVED_TMP="nik_reserved_v4_t"
SET_CHINA="nik_china_v4"
SET_CHINA_TMP="nik_china_v4_t"

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

# Resolve only the listeners required by the selected backend modes. This lets
# users disable DNS, TCP or UDP independently without needing unused ports.
load_ports() {
	local redirect_listener tproxy_listener dns_listen
	REDIR_PORT=''
	TPROXY_PORT=''
	DNS_PORT=''
	config_get redirect_listener core redirect_listener_name redir-in
	config_get tproxy_listener core tproxy_listener_name tproxy-in

	if [ "$IPV4_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ]; then
		REDIR_PORT="$(REDIRECT_LISTENER="$redirect_listener" yq -M -r '."redir-port" // (.listeners[]? | select(.name == env(REDIRECT_LISTENER) and .type == "redir") | .port) // ""' "$RUN_PROFILE_PATH" 2>/dev/null)"
		valid_port "$REDIR_PORT" || return 1
	fi

	if [ "$IPV4_PROXY" -eq 1 ] && [ "$UDP_MODE" = tproxy ]; then
		TPROXY_PORT="$(TPROXY_LISTENER="$tproxy_listener" yq -M -r '."tproxy-port" // (.listeners[]? | select(.name == env(TPROXY_LISTENER) and .type == "tproxy") | .port) // ""' "$RUN_PROFILE_PATH" 2>/dev/null)"
		valid_port "$TPROXY_PORT" || return 1
	fi

	if [ "$IPV4_DNS_HIJACK" -eq 1 ]; then
		dns_listen="$(yq -M -r '.dns.listen // ""' "$RUN_PROFILE_PATH" 2>/dev/null)"
		DNS_PORT="$(extract_listen_port "$dns_listen")"
		valid_port "$DNS_PORT" || return 1
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

prepare_ipsets() {
	: > "$IPSET_FILE"
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	create $SET_RESERVED hash:net family inet hashsize 128 maxelem 1024 -exist
	create $SET_RESERVED_TMP hash:net family inet hashsize 128 maxelem 1024 -exist
	flush $SET_RESERVED_TMP
	EOF_IPSET

	_add_reserved_ip() {
		valid_ipv4_or_cidr "$1" && printf 'add %s %s -exist\n' "$SET_RESERVED_TMP" "$1" >> "$IPSET_FILE"
	}
	config_list_foreach proxy reserved_ip _add_reserved_ip
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_RESERVED_TMP $SET_RESERVED
	destroy $SET_RESERVED_TMP
	create $SET_CHINA hash:net family inet hashsize 4096 maxelem 65536 -exist
	create $SET_CHINA_TMP hash:net family inet hashsize 4096 maxelem 65536 -exist
	flush $SET_CHINA_TMP
	EOF_IPSET

	if [ "$BYPASS_CHINA" -eq 1 ] && [ -r "$CHINA_IP_FILE" ]; then
		awk -v set="$SET_CHINA_TMP" 'NF && $1 !~ /^#/ { print "add " set " " $1 " -exist" }' "$CHINA_IP_FILE" >> "$IPSET_FILE"
	fi
	cat >> "$IPSET_FILE" <<-EOF_IPSET
	swap $SET_CHINA_TMP $SET_CHINA
	destroy $SET_CHINA_TMP
	EOF_IPSET

	$IPSET restore < "$IPSET_FILE"
}

remove_jump() {
	local table="$1" builtin="$2" chain="$3"
	while $IPT -t "$table" -C "$builtin" -j "$chain" >/dev/null 2>&1; do
		$IPT -t "$table" -D "$builtin" -j "$chain" >/dev/null 2>&1 || break
	done
}

remove_chain() {
	local table="$1" chain="$2"
	$IPT -t "$table" -F "$chain" >/dev/null 2>&1
	$IPT -t "$table" -X "$chain" >/dev/null 2>&1
}

remove_rules_only() {
	remove_jump nat PREROUTING "$NAT_PRE_DNS"
	remove_jump nat PREROUTING "$NAT_PRE_TCP"
	remove_jump nat OUTPUT "$NAT_OUT_DNS"
	remove_jump nat OUTPUT "$NAT_OUT_TCP"
	remove_jump mangle PREROUTING "$MGL_PRE_CTRL"
	remove_jump mangle OUTPUT "$MGL_OUT_MARK"

	remove_chain nat "$NAT_PRE_DNS"
	remove_chain nat "$NAT_PRE_TCP"
	remove_chain nat "$NAT_OUT_DNS"
	remove_chain nat "$NAT_OUT_TCP"
	remove_chain mangle "$MGL_PRE_CTRL"
	remove_chain mangle "$MGL_PRE_TPROXY"
	remove_chain mangle "$MGL_OUT_MARK"
}

remove_all() {
	acquire_lock || return 1
	remove_rules_only
	$IPSET destroy "$SET_RESERVED" >/dev/null 2>&1
	$IPSET destroy "$SET_RESERVED_TMP" >/dev/null 2>&1
	$IPSET destroy "$SET_CHINA" >/dev/null 2>&1
	$IPSET destroy "$SET_CHINA_TMP" >/dev/null 2>&1
	release_lock
}

rule() {
	# Append one iptables-restore rule verbatim.
	printf '%s\n' "$*" >> "$RULES_FILE"
}

normalize_port_tokens() {
	local input="$1" token output="" count=0 chunk="" first last normalized
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
	# $1 chain, $2 base match, $3 target; protocol must already be in base.
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
	# $1 chain, $2 base match (usually -i DEV -p tcp/udp)
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
LAN_HAS_SELECTOR=0
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
			# DNS opted into hijacking must reach nat/PREROUTING instead of TPROXY.
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
	LAN_HAS_SELECTOR=1
	valid_ipv4_or_cidr "$1" && _emit_lan_proxy_target "-s $1" "$LAN_DNS" "$LAN_ACL_PROXY"
}

_emit_lan_mac() {
	LAN_HAS_SELECTOR=1
	printf '%s' "$1" | grep -Eqi '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' && \
		_emit_lan_proxy_target "-m mac --mac-source $1" "$LAN_DNS" "$LAN_ACL_PROXY"
}

_emit_lan_acl_section() {
	local section="$1" enabled unsupported_ip6
	config_get_bool enabled "$section" enabled 0
	[ "$enabled" -eq 1 ] || return 0
	config_get_bool LAN_DNS "$section" dns 0
	config_get_bool LAN_ACL_PROXY "$section" proxy 0
	LAN_HAS_SELECTOR=0
	config_list_foreach "$section" ip _emit_lan_ip
	config_list_foreach "$section" mac _emit_lan_mac
	unsupported_ip6="$(list_count "$section" ip6)"
	if [ "$LAN_HAS_SELECTOR" -eq 0 ] && [ "$unsupported_ip6" -eq 0 ]; then
		_emit_lan_proxy_target "" "$LAN_DNS" "$LAN_ACL_PROXY"
	fi
}

emit_lan_acl() {
	# $1 chain, $2 interface, $3 kind dns|tcp|udp
	LAN_CHAIN="$1"
	LAN_BASE="-i $2"
	LAN_KIND="$3"
	LAN_DNS_PORT="$DNS_PORT"
	config_foreach _emit_lan_acl_section lan_access_control
}

RTR_CHAIN=""
RTR_KIND=""
RTR_HAS_SELECTOR=0
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

generate_rules() {
	: > "$RULES_FILE"
	cat >> "$RULES_FILE" <<-EOF_RULES
	*nat
	:$NAT_PRE_DNS - [0:0]
	:$NAT_PRE_TCP - [0:0]
	:$NAT_OUT_DNS - [0:0]
	:$NAT_OUT_TCP - [0:0]
	EOF_RULES

	# Every -I ... 1 becomes the new first rule. Emit TCP first and DNS second
	# so DNS remains ahead of the broad TCP redirect in the installed chain.
	[ "$LAN_PROXY_ENABLED" -eq 1 ] && [ "$IPV4_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ] && rule "-I PREROUTING 1 -j $NAT_PRE_TCP"
	[ "$LAN_PROXY_ENABLED" -eq 1 ] && [ "$IPV4_DNS_HIJACK" -eq 1 ] && rule "-I PREROUTING 1 -j $NAT_PRE_DNS"
	[ "$ROUTER_PROXY" -eq 1 ] && [ "$IPV4_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ] && rule "-I OUTPUT 1 -j $NAT_OUT_TCP"
	[ "$ROUTER_PROXY" -eq 1 ] && [ "$IPV4_DNS_HIJACK" -eq 1 ] && rule "-I OUTPUT 1 -j $NAT_OUT_DNS"

	if [ "$LAN_PROXY_ENABLED" -eq 1 ]; then
		for dev in $LAN_DEVICES; do
			[ "$IPV4_DNS_HIJACK" -eq 1 ] && emit_lan_acl "$NAT_PRE_DNS" "$dev" dns
			if [ "$IPV4_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ]; then
				emit_common_bypass "$NAT_PRE_TCP" "-i $dev -p tcp"
				normalize_port_tokens "$PROXY_TCP_DPORT"
				emit_lan_acl "$NAT_PRE_TCP" "$dev" tcp
			fi
		done
	fi

	if [ "$ROUTER_PROXY" -eq 1 ]; then
		if [ "$IPV4_DNS_HIJACK" -eq 1 ]; then
			rule "-A $NAT_OUT_DNS -m mark --mark $CORE_MARK/$CORE_MASK -j RETURN"
			emit_router_acl "$NAT_OUT_DNS" dns
		fi
		if [ "$IPV4_PROXY" -eq 1 ] && [ "$TCP_MODE" = redirect ]; then
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

	if [ "$IPV4_PROXY" -eq 1 ] && [ "$UDP_MODE" = tproxy ]; then
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
	config_get_bool IPV4_DNS_HIJACK proxy ipv4_dns_hijack 1
	config_get_bool ROUTER_PROXY proxy router_proxy 1
	config_get_bool LAN_PROXY_ENABLED proxy lan_proxy 1
	config_get_bool BYPASS_CHINA proxy bypass_china_mainland_ip 0
	config_get PROXY_TCP_DPORT proxy proxy_tcp_dport 0-65535
	config_get PROXY_UDP_DPORT proxy proxy_udp_dport 0-65535

	config_get TPROXY_MARK routing tproxy_fw_mark 0x80
	config_get TPROXY_MASK routing tproxy_fw_mask 0xFF
	config_get CORE_MARK routing core_fw_mark 0x82
	config_get CORE_MASK routing core_fw_mask 0xFF

	LAN_DEVICES=""
	config_list_foreach proxy lan_inbound_interface _add_lan_device
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
	if [ "$IPV4_PROXY" -ne 1 ] && [ "$IPV4_DNS_HIJACK" -ne 1 ]; then
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

	if [ "$IPV4_PROXY" -eq 1 ]; then
		prepare_ipsets || {
			log "Firewall" "Failed to prepare ipsets."
			release_lock
			return 1
		}
	fi
	remove_rules_only
	generate_rules
	if iptables-restore --noflush < "$RULES_FILE"; then
		log "Firewall" "iptables rules applied."
		release_lock
		return 0
	fi

	log "Firewall" "iptables-restore failed; removing partial rules."
	remove_rules_only
	release_lock
	return 1
}

render_rules() {
	prepare_files
	load_config
	[ -r "$RUN_PROFILE_PATH" ] || return 1
	load_ports || return 1
	generate_rules
	cat "$RULES_FILE"
}

check_backend() {
	command_exists "$IPT" || return 1
	command_exists iptables-restore || return 1
	command_exists "$IPSET" || return 1
	$IPT -t mangle -j TPROXY -h >/dev/null 2>&1 || return 1
	$IPT -m owner -h >/dev/null 2>&1 || return 1
	$IPT -m set -h >/dev/null 2>&1 || return 1
	return 0
}

prepare_files

case "${1:-apply}" in
	apply|reload)
		check_backend || {
			log "Firewall" "Required iptables extensions are unavailable."
			exit 1
		}
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
