# Nikki Legacy V6 release audit

## Scope

This audit cross-checked LuCI controls, UCI defaults and migration, RPC helper commands, init/runtime consumption, firewall rendering, core updater state, ACL/menu files, translations and packaging inputs.

## Automated validation

- POSIX `/bin/sh` and BusyBox `ash` syntax checks for all shell/init/helper files.
- Node.js syntax checks for every LuCI JavaScript file.
- JSON parsing for menu and RPC ACL declarations.
- Field/action contract checks across LuCI, RPC and backend commands.
- Default mixin generation: warning/rule/off, TUN disabled, DNS enabled at `[::]:1053`, optional overrides omitted.
- Default firewall rendering: IPv4/IPv6 TCP+UDP TPROXY and IPv4/IPv6 DNS REDIRECT to the dual-stack Mihomo DNS listener on 1053.
- Independent REDIRECT/TPROXY/TUN combinations, IPv6 no-NAT invariant, ACLs and policy routes.
- Core update/check/rollback/delete, architecture matching, ShellCrash fallback, stale lock, insufficient/failed-restart recovery, both-slot preservation and safe archive extraction.
- RPC controller wildcard normalization and transactional editor writes.
- Translation completeness and LuCI menu target existence.

## Issues fixed during audit

1. Proxy-server nameserver-policy overwrite merged instead of replacing.
2. A zero TUN polling interval could loop indefinitely.
3. Failed core activation restored the active slot but could lose the previous slot.
4. Reapplying configuration could duplicate or retain stale cron entries.
5. Legacy custom ShellCrash settings could display a different preset in LuCI.
6. Migrated scheduled restart could be enabled without its default cron expression.
7. A stale updater lock could block future updates.
8. Scheme-prefixed IPv6 wildcard controller addresses were not normalized to loopback.
9. Resolved-source state and several translation strings were incomplete.
10. Runtime dependencies were partly implicit.
11. Tar releases were fully unpacked instead of streaming one validated member.
12. Chunked editor writes could expose a partially written file after interruption.

## Remaining verification boundary

The source passes the repository test suite and host-side compatibility checks. It has not been compiled inside an actual OpenWrt 21.02 SDK in this environment and has not completed physical-router traffic, reboot, sysupgrade, storage-pressure and network-failure regression testing. Those are required before claiming production-grade or bug-free status.
