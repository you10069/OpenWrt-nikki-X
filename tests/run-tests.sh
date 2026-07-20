#!/bin/sh
set -eu

TEST_FILE="$(dirname "$0")/test_legacy.py"
TESTS='
test_static
test_mixin
test_default_mixin_policy
test_firewall
test_default_firewall_modes
test_ipv4_tcp_tproxy
test_ipv6_tcp_redirect
test_ipv4_dns_tproxy
test_ipv6_dns_only
test_ipv6_dns_redirect_only
test_dns_tun_only
test_firewall_apply
test_tun_policy_routes
test_core_space_policy
test_firmware_core_symlink
test_core_update
test_official_source_channels
test_shellcrash_repository_update
test_shellcrash_automatic_https_fallback
test_core_source_change_status
test_core_archive_extraction
test_rpc_transactional_write
test_rpc_ipv6_wildcard
test_rpc_firewall_backend_detection
test_frontend_backend_contracts
'

for test_name in $TESTS; do
    printf 'Running %s...\n' "$test_name"
    timeout -k 5 90 python3 "$TEST_FILE" "$test_name"
done

printf '%s\n' 'All Nikki Legacy tests passed.'
