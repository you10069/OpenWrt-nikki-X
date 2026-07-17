#!/bin/sh

# Generate a JSON Mihomo mixin from /etc/config/nikki without ucode.
# The JSON output is consumed by yq in /etc/init.d/nikki.

. /lib/functions.sh
. /usr/share/libubox/jshn.sh

CONFIG_PACKAGE="nikki"

is_true() {
	case "$1" in
		1|true|yes|on) return 0 ;;
		*) return 1 ;;
	esac
}

json_add_string_opt() {
	local key="$1" section="$2" option="$3" value
	config_get value "$section" "$option"
	[ -n "$value" ] && json_add_string "$key" "$value"
}

json_add_int_opt() {
	local key="$1" section="$2" option="$3" value
	config_get value "$section" "$option"
	[ -n "$value" ] || return 0
	case "$value" in
		0x*|0X*) value=$((value)) ;;
	esac
	json_add_int "$key" "$value"
}

json_add_bool_opt() {
	local key="$1" section="$2" option="$3" value
	config_get value "$section" "$option"
	[ -n "$value" ] || return 0
	if is_true "$value"; then
		json_add_boolean "$key" 1
	else
		json_add_boolean "$key" 0
	fi
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

_add_list_string() {
	json_add_string "" "$1"
}

json_add_list_opt() {
	local key="$1" section="$2" option="$3" count
	count="$(list_count "$section" "$option")"
	[ "$count" -gt 0 ] || return 0
	json_add_array "$key"
	config_list_foreach "$section" "$option" _add_list_string
	json_close_array
}

section_enabled() {
	local enabled
	config_get_bool enabled "$1" enabled 0
	[ "$enabled" -eq 1 ]
}

_COUNT=0
_count_authentication() {
	local section="$1" username
	section_enabled "$section" || return 0
	config_get username "$section" username
	[ -n "$username" ] && _COUNT=$((_COUNT + 1))
}

_add_authentication() {
	local section="$1" username password
	section_enabled "$section" || return 0
	config_get username "$section" username
	[ -n "$username" ] || return 0
	config_get password "$section" password
	json_add_string "" "${username}:${password}"
}

_count_hosts() {
	local section="$1" domain
	section_enabled "$section" || return 0
	config_get domain "$section" domain_name
	[ -n "$domain" ] && [ "$(list_count "$section" ip)" -gt 0 ] && _COUNT=$((_COUNT + 1))
}

_add_host() {
	local section="$1" domain
	section_enabled "$section" || return 0
	config_get domain "$section" domain_name
	[ -n "$domain" ] || return 0
	[ "$(list_count "$section" ip)" -gt 0 ] || return 0
	json_add_array "$domain"
	config_list_foreach "$section" ip _add_list_string
	json_close_array
}

_count_nameserver_type() {
	local section="$1" wanted="$2" type
	section_enabled "$section" || return 0
	config_get type "$section" type
	[ "$type" = "$wanted" ] || return 0
	_COUNT=$((_COUNT + $(list_count "$section" nameserver)))
}

_add_nameserver_type() {
	local section="$1" wanted="$2" type
	section_enabled "$section" || return 0
	config_get type "$section" type
	[ "$type" = "$wanted" ] || return 0
	config_list_foreach "$section" nameserver _add_list_string
}

_count_policy() {
	local section="$1" matcher
	section_enabled "$section" || return 0
	config_get matcher "$section" matcher
	[ -n "$matcher" ] && [ "$(list_count "$section" nameserver)" -gt 0 ] && _COUNT=$((_COUNT + 1))
}

_add_policy() {
	local section="$1" matcher
	section_enabled "$section" || return 0
	config_get matcher "$section" matcher
	[ -n "$matcher" ] || return 0
	[ "$(list_count "$section" nameserver)" -gt 0 ] || return 0
	json_add_array "$matcher"
	config_list_foreach "$section" nameserver _add_list_string
	json_close_array
}

_count_sniff() {
	local section="$1" protocol
	section_enabled "$section" || return 0
	config_get protocol "$section" protocol
	[ -n "$protocol" ] && _COUNT=$((_COUNT + 1))
}

_add_sniff() {
	local section="$1" protocol overwrite
	section_enabled "$section" || return 0
	config_get protocol "$section" protocol
	[ -n "$protocol" ] || return 0
	json_add_object "$protocol"
	json_add_list_opt port "$section" port
	config_get_bool overwrite "$section" overwrite_destination 0
	json_add_boolean override-destination "$overwrite"
	json_close_object
}

_count_rule_provider() {
	local section="$1" name type
	section_enabled "$section" || return 0
	config_get name "$section" name
	config_get type "$section" type
	[ -n "$name" ] && { [ "$type" = http ] || [ "$type" = file ]; } && _COUNT=$((_COUNT + 1))
}

_add_rule_provider() {
	local section="$1" name type
	section_enabled "$section" || return 0
	config_get name "$section" name
	config_get type "$section" type
	[ -n "$name" ] || return 0
	[ "$type" = http ] || [ "$type" = file ] || return 0

	json_add_object "$name"
	json_add_string type "$type"
	if [ "$type" = http ]; then
		json_add_string_opt url "$section" url
		json_add_string_opt proxy "$section" node
		json_add_int_opt size_limit "$section" file_size_limit
		json_add_string_opt format "$section" file_format
		json_add_string_opt behavior "$section" behavior
		json_add_int_opt interval "$section" update_interval
	else
		json_add_string_opt path "$section" file_path
		json_add_string_opt format "$section" file_format
		json_add_string_opt behavior "$section" behavior
	fi
	json_close_object
}

_count_rule() {
	local section="$1" type matcher node
	section_enabled "$section" || return 0
	config_get type "$section" type
	config_get matcher "$section" matcher
	config_get node "$section" node
	[ -n "$type" ] && [ -n "$matcher" ] && [ -n "$node" ] && _COUNT=$((_COUNT + 1))
}

_add_rule() {
	local section="$1" type matcher node no_resolve rule
	section_enabled "$section" || return 0
	config_get type "$section" type
	config_get matcher "$section" matcher
	config_get node "$section" node
	[ -n "$type" ] && [ -n "$matcher" ] && [ -n "$node" ] || return 0
	config_get_bool no_resolve "$section" no_resolve 0
	rule="${type},${matcher},${node}"
	[ "$no_resolve" -eq 1 ] && rule="${rule},no-resolve"
	json_add_string "" "$rule"
}

config_load "$CONFIG_PACKAGE"
json_init

# General
json_add_string_opt log-level mixin log_level
json_add_string_opt mode mixin mode
json_add_string_opt find-process-mode mixin match_process

config_get outbound_interface mixin outbound_interface
if [ -n "$outbound_interface" ]; then
	outbound_status="$(ubus call "network.interface.${outbound_interface}" status 2>/dev/null)"
	outbound_device="$(printf '%s' "$outbound_status" | jsonfilter -e '@.l3_device' 2>/dev/null)"
	[ -n "$outbound_device" ] || outbound_device="$(printf '%s' "$outbound_status" | jsonfilter -e '@.device' 2>/dev/null)"
	[ -n "$outbound_device" ] && json_add_string interface-name "$outbound_device"
fi

json_add_bool_opt ipv6 mixin ipv6
json_add_bool_opt unified-delay mixin unify_delay
json_add_bool_opt tcp-concurrent mixin tcp_concurrent
json_add_bool_opt disable-keep-alive mixin disable_tcp_keep_alive
json_add_int_opt keep-alive-idle mixin tcp_keep_alive_idle
json_add_int_opt keep-alive-interval mixin tcp_keep_alive_interval

# Dashboard and API
json_add_string_opt external-ui mixin ui_path
json_add_string_opt external-ui-name mixin ui_name
json_add_string_opt external-ui-url mixin ui_url
json_add_string_opt external-controller mixin api_listen
json_add_string_opt external-controller-tls mixin api_tls_listen

config_get api_tls_cert mixin api_tls_cert
config_get api_tls_key mixin api_tls_key
config_get api_tls_ech_key mixin api_tls_ech_key
if [ -n "$api_tls_cert$api_tls_key$api_tls_ech_key" ]; then
	json_add_object tls
	[ -n "$api_tls_cert" ] && json_add_string certificate "$api_tls_cert"
	[ -n "$api_tls_key" ] && json_add_string private-key "$api_tls_key"
	[ -n "$api_tls_ech_key" ] && json_add_string ech-key "$api_tls_ech_key"
	json_close_object
fi
json_add_string_opt secret mixin api_secret

# Listener ports
json_add_bool_opt allow-lan mixin allow_lan
json_add_int_opt port mixin http_port
json_add_int_opt socks-port mixin socks_port
json_add_int_opt mixed-port mixin mixed_port
json_add_int_opt redir-port mixin redir_port
json_add_int_opt tproxy-port mixin tproxy_port

# Make every Mihomo-originated outbound socket carry a distinct mark. The
# firewall backend excludes this mark to prevent proxy loops.
config_get core_fw_mark routing core_fw_mark 0x82
json_add_int routing-mark "$((core_fw_mark))"

# Authentication
config_get_bool authentication_enabled mixin authentication 0
if [ "$authentication_enabled" -eq 1 ]; then
	_COUNT=0
	config_foreach _count_authentication authentication
	if [ "$_COUNT" -gt 0 ]; then
		json_add_array authentication
		config_foreach _add_authentication authentication
		json_close_array
	fi
fi

# TUN settings are used by the legacy firewall backend when any per-family
# TCP/UDP mode selects TUN. The init script disables Mihomo auto-route and
# installs explicit fwmark policy routes instead.
json_add_object tun
json_add_bool_opt enable mixin tun_enabled
json_add_string_opt device mixin tun_device
json_add_string_opt stack mixin tun_stack
json_add_int_opt mtu mixin tun_mtu
json_add_bool_opt gso mixin tun_gso
json_add_int_opt gso-max-size mixin tun_gso_max_size
config_get_bool tun_dns_hijack mixin tun_dns_hijack 0
[ "$tun_dns_hijack" -eq 1 ] && json_add_list_opt dns-hijack mixin tun_dns_hijacks
json_close_object

# DNS
json_add_object dns
json_add_bool_opt enable mixin dns_enabled
json_add_string_opt cache-algorithm mixin dns_cache_algorithm
json_add_string_opt listen mixin dns_listen
json_add_bool_opt ipv6 mixin dns_ipv6
json_add_string_opt enhanced-mode mixin dns_mode
json_add_string_opt fake-ip-range mixin fake_ip_range
json_add_string_opt fake-ip-range6 mixin fake_ip6_range
json_add_int_opt fake-ip-ttl mixin fake_ip_ttl
config_get_bool fake_ip_filter mixin fake_ip_filter 0
[ "$fake_ip_filter" -eq 1 ] && json_add_list_opt fake-ip-filter mixin fake_ip_filters
json_add_string_opt fake-ip-filter-mode mixin fake_ip_filter_mode
json_add_bool_opt respect-rules mixin dns_respect_rules
json_add_bool_opt prefer-h3 mixin dns_doh_prefer_http3
json_add_bool_opt use-system-hosts mixin dns_system_hosts
json_add_bool_opt use-hosts mixin dns_hosts

config_get_bool dns_nameserver mixin dns_nameserver 0
if [ "$dns_nameserver" -eq 1 ]; then
	for ns_type in default-nameserver proxy-server-nameserver direct-nameserver nameserver fallback; do
		_COUNT=0
		config_foreach _count_nameserver_type nameserver "$ns_type"
		if [ "$_COUNT" -gt 0 ]; then
			json_add_array "$ns_type"
			config_foreach _add_nameserver_type nameserver "$ns_type"
			json_close_array
		fi
	done
fi

config_get_bool dns_proxy_policy mixin dns_proxy_server_nameserver_policy 0
if [ "$dns_proxy_policy" -eq 1 ]; then
	_COUNT=0
	config_foreach _count_policy proxy_server_nameserver_policy
	if [ "$_COUNT" -gt 0 ]; then
		json_add_object proxy-server-nameserver-policy
		config_foreach _add_policy proxy_server_nameserver_policy
		json_close_object
	fi
fi
json_add_bool_opt direct-nameserver-follow-policy mixin dns_direct_nameserver_follow_policy

config_get_bool dns_policy mixin dns_nameserver_policy 0
if [ "$dns_policy" -eq 1 ]; then
	_COUNT=0
	config_foreach _count_policy nameserver_policy
	if [ "$_COUNT" -gt 0 ]; then
		json_add_object nameserver-policy
		config_foreach _add_policy nameserver_policy
		json_close_object
	fi
fi
json_close_object

# Hosts
config_get_bool hosts_enabled mixin hosts 0
if [ "$hosts_enabled" -eq 1 ]; then
	_COUNT=0
	config_foreach _count_hosts hosts
	if [ "$_COUNT" -gt 0 ]; then
		json_add_object hosts
		config_foreach _add_host hosts
		json_close_object
	fi
fi

# Sniffer
config_get sniffer_enable mixin sniffer
config_get sniffer_dns mixin sniffer_sniff_dns_mapping
config_get sniffer_pure mixin sniffer_sniff_pure_ip
config_get_bool force_domains mixin sniffer_force_domain_name 0
config_get_bool skip_domains mixin sniffer_ignore_domain_name 0
config_get_bool sniff_map mixin sniffer_sniff 0
_COUNT=0
[ "$sniff_map" -eq 1 ] && config_foreach _count_sniff sniff
if [ -n "$sniffer_enable$sniffer_dns$sniffer_pure" ] || [ "$force_domains" -eq 1 ] || [ "$skip_domains" -eq 1 ] || [ "$_COUNT" -gt 0 ]; then
	json_add_object sniffer
	json_add_bool_opt enable mixin sniffer
	json_add_bool_opt force-dns-mapping mixin sniffer_sniff_dns_mapping
	json_add_bool_opt parse-pure-ip mixin sniffer_sniff_pure_ip
	[ "$force_domains" -eq 1 ] && json_add_list_opt force-domain mixin sniffer_force_domain_names
	[ "$skip_domains" -eq 1 ] && json_add_list_opt skip-domain mixin sniffer_ignore_domain_names
	if [ "$sniff_map" -eq 1 ] && [ "$_COUNT" -gt 0 ]; then
		json_add_object sniff
		config_foreach _add_sniff sniff
		json_close_object
	fi
	json_close_object
fi

# Runtime profile cache
json_add_object profile
json_add_bool_opt store-selected mixin selection_cache
json_add_bool_opt store-fake-ip mixin fake_ip_cache
json_close_object

# Rule providers
config_get_bool rule_provider_enabled mixin rule_provider 0
if [ "$rule_provider_enabled" -eq 1 ]; then
	_COUNT=0
	config_foreach _count_rule_provider rule_provider
	if [ "$_COUNT" -gt 0 ]; then
		json_add_object rule-providers
		config_foreach _add_rule_provider rule_provider
		json_close_object
	fi
fi

# Prepend rules
config_get_bool rule_enabled mixin rule 0
if [ "$rule_enabled" -eq 1 ]; then
	_COUNT=0
	config_foreach _count_rule rule
	if [ "$_COUNT" -gt 0 ]; then
		json_add_array nikki-rules
		config_foreach _add_rule rule
		json_close_array
	fi
fi

# Geodata
config_get geoip_format mixin geoip_format
if [ -n "$geoip_format" ]; then
	[ "$geoip_format" = dat ] && json_add_boolean geodata-mode 1 || json_add_boolean geodata-mode 0
fi
json_add_string_opt geodata-loader mixin geodata_loader
config_get geosite_url mixin geosite_url
config_get geoip_mmdb_url mixin geoip_mmdb_url
config_get geoip_dat_url mixin geoip_dat_url
config_get geoip_asn_url mixin geoip_asn_url
if [ -n "$geosite_url$geoip_mmdb_url$geoip_dat_url$geoip_asn_url" ]; then
	json_add_object geox-url
	[ -n "$geosite_url" ] && json_add_string geosite "$geosite_url"
	[ -n "$geoip_mmdb_url" ] && json_add_string mmdb "$geoip_mmdb_url"
	[ -n "$geoip_dat_url" ] && json_add_string geoip "$geoip_dat_url"
	[ -n "$geoip_asn_url" ] && json_add_string asn "$geoip_asn_url"
	json_close_object
fi
json_add_bool_opt geo-auto-update mixin geox_auto_update
json_add_int_opt geo-update-interval mixin geox_update_interval

json_dump
