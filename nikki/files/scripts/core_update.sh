#!/bin/sh

# Nikki-X single-slot Mihomo core updater for OpenWrt 21.02 / BusyBox ash.
# A user-requested update downloads and validates the payload before replacing
# the managed core whenever storage permits. In the low-space pre-delete path,
# replacing the old core first remains unavoidable.

HOME_DIR="${HOME_DIR:-/etc/nikki}"
CORE_DIR="${CORE_DIR:-/usr/libexec/nikki}"
CORE_ACTIVE="${CORE_ACTIVE:-$CORE_DIR/mihomo}"
STATE_FILE="${STATE_FILE:-$HOME_DIR/core-update.state}"
LOCK_DIR="${LOCK_DIR:-/var/lock/nikki-core-update.lock}"
TEMP_ROOT="${TEMP_ROOT:-/tmp}"
UCI_BIN="${UCI_BIN:-uci}"
CURL_BIN="${CURL_BIN:-curl}"
YQ_BIN="${YQ_BIN:-yq}"
OPKG_BIN="${OPKG_BIN:-opkg}"
APK_BIN="${APK_BIN:-apk}"
UNAME_BIN="${UNAME_BIN:-uname}"
SERVICE_BIN="${SERVICE_BIN:-/etc/init.d/nikki}"
USER_AGENT="nikki-core-updater"

API_TIMEOUT=10
PROBE_TIMEOUT=5
NO_RESPONSE_TIMEOUT=20
UPDATE_TASK_TIMEOUT=900
DOWNLOAD_ATTEMPTS=3
MIB_KB=1024

SOURCE_TYPE=official
OFFICIAL_REPOSITORY=MetaCubeX/mihomo
OFFICIAL_PRESET=auto
REPOSITORY_PRESET=auto
REPOSITORY_URL=
RELEASES_URL=https://github.com/MetaCubeX/mihomo/releases
RELEASES_TAG=latest
DIRECT_URL=

RESOLVED_OFFICIAL_DOWNLOAD_CHANNEL=
RESOLVED_REPOSITORY_BASE=
RESOLVED_URL=
RESOLVED_ASSET=
LATEST_VERSION=
ERROR_KIND=
UPDATE_DEADLINE=0

cleanup_paths=
lock_held=0

cleanup() {
	local item
	for item in $cleanup_paths; do
		rm -rf "$item" 2>/dev/null
	done
	if [ "$lock_held" -eq 1 ]; then
		rm -f "$LOCK_DIR/pid" 2>/dev/null
		rmdir "$LOCK_DIR" 2>/dev/null
	fi
}
trap cleanup EXIT INT TERM

trim_slash() {
	printf '%s' "$1" | sed 's:/*$::'
}

single_line() {
	printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

state_get() {
	local key="$1"
	[ -r "$STATE_FILE" ] || return 0
	sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n 1
}

state_set() {
	local key="$1" value tmp
	value="$(single_line "$2")"
	mkdir -p "$(dirname "$STATE_FILE")" || return 1
	tmp="${STATE_FILE}.tmp.$$"
	if [ -r "$STATE_FILE" ]; then
		grep -v "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || :
	else
		: > "$tmp"
	fi
	printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
	chmod 600 "$tmp" 2>/dev/null
	mv -f "$tmp" "$STATE_FILE"
}

set_status() {
	state_set last_status "$1"
	state_set last_error "${2:-}"
	state_set last_update "$(date '+%Y-%m-%d %H:%M:%S')"
}

fail() {
	set_status error "$1" >/dev/null 2>&1 || :
	printf '%s\n' "$1" >&2
	return 1
}

acquire_lock() {
	local owner
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || :
		lock_held=1
		return 0
	fi
	owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
	case "$owner" in ''|*[!0-9]*) owner= ;; esac
	if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
		rm -rf "$LOCK_DIR" 2>/dev/null
		if mkdir "$LOCK_DIR" 2>/dev/null; then
			printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || :
			lock_held=1
			return 0
		fi
	fi
	printf '%s\n' '已有更新任务正在运行，请等待几分钟后重试' >&2
	return 1
}

uci_get() {
	"$UCI_BIN" -q get "$1" 2>/dev/null
}

load_config() {
	local value
	value="$(uci_get nikki.core_update.source_type)"; [ -n "$value" ] && SOURCE_TYPE="$value"
	value="$(uci_get nikki.core_update.official_repository)"; [ -n "$value" ] && OFFICIAL_REPOSITORY="$value"
	value="$(uci_get nikki.core_update.official_preset)"; [ -n "$value" ] && OFFICIAL_PRESET="$value"
	value="$(uci_get nikki.core_update.repository_preset)"; [ -n "$value" ] && REPOSITORY_PRESET="$value"
	value="$(uci_get nikki.core_update.repository_url)"; [ -n "$value" ] && REPOSITORY_URL="$value"
	value="$(uci_get nikki.core_update.releases_url)"; [ -n "$value" ] && RELEASES_URL="$value"
	value="$(uci_get nikki.core_update.releases_tag)"; [ -n "$value" ] && RELEASES_TAG="$value"
	value="$(uci_get nikki.core_update.direct_url)"; [ -n "$value" ] && DIRECT_URL="$value"

	case "$SOURCE_TYPE" in official|repository|release|direct) ;; *) SOURCE_TYPE=official ;; esac
	case "$OFFICIAL_PRESET" in auto|proxy|proxynet|github) ;; *) OFFICIAL_PRESET=auto ;; esac
	case "$REPOSITORY_PRESET" in auto|cloudflare|jsdelivr|github|author_https|author_http|custom) ;; *) REPOSITORY_PRESET=auto ;; esac
}

source_key() {
	case "$SOURCE_TYPE" in
		official) printf 'official|%s|%s' "$OFFICIAL_REPOSITORY" "$OFFICIAL_PRESET" ;;
		repository) printf 'repository|%s|%s' "$REPOSITORY_PRESET" "$(trim_slash "$REPOSITORY_URL")" ;;
		release) printf 'release|%s|%s' "$(trim_slash "$RELEASES_URL")" "$RELEASES_TAG" ;;
		direct) printf 'direct|%s' "$DIRECT_URL" ;;
	esac
}

core_version() {
	local path="$1" output version
	[ -x "$path" ] || return 0
	if command -v timeout >/dev/null 2>&1; then
		output="$(timeout 10 "$path" -v 2>/dev/null | head -n 2)"
	else
		output="$("$path" -v 2>/dev/null | head -n 2)"
	fi
	version="$(printf '%s\n' "$output" | sed -n 's/.*\(v[0-9][0-9A-Za-z._+-]*\).*/\1/p' | head -n 1)"
	[ -n "$version" ] || version="$(printf '%s\n' "$output" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^(alpha-|meta-)?[0-9]/) { print $i; exit } }')"
	printf '%s' "$version"
}

package_architecture() {
	local arch
	arch=
	if command -v "$OPKG_BIN" >/dev/null 2>&1; then
		arch="$("$OPKG_BIN" print-architecture 2>/dev/null | awk '$2 != "all" && $2 != "noarch" { p=$3+0; if (p >= best) { best=p; name=$2 } } END { print name }')"
	fi
	if [ -z "$arch" ] && command -v "$APK_BIN" >/dev/null 2>&1; then
		arch="$("$APK_BIN" --print-arch 2>/dev/null | head -n 1)"
	fi
	printf '%s' "$arch"
}

system_architecture() {
	local package uname_arch combined
	package="$(package_architecture)"
	uname_arch="$("$UNAME_BIN" -m 2>/dev/null)"
	combined="${package}:${uname_arch}"
	case "$combined" in
		*aarch64*|*arm64*) printf 'arm64' ;;
		*arm_cortex-a5*|*arm_cortex-a7*|*arm_cortex-a8*|*arm_cortex-a9*|*arm_cortex-a15*|*armv7*) printf 'armv7' ;;
		*armv6*) printf 'armv6' ;;
		*armv5*) printf 'armv5' ;;
		*x86_64*|*amd64*) printf 'amd64-compatible' ;;
		*i386*|*i486*|*i586*|*i686*) printf '386' ;;
		*mips64el*|*mips64le*) printf 'mips64le' ;;
		*mips64*) printf 'mips64' ;;
		*mipsel*hardfloat*|*mipsle*hardfloat*) printf 'mipsle-hardfloat' ;;
		*mipsel*|*mipsle*) printf 'mipsle-softfloat' ;;
		*mips*hardfloat*) printf 'mips-hardfloat' ;;
		*mips*) printf 'mips-softfloat' ;;
		*riscv64*) printf 'riscv64' ;;
		*loongarch64*|*loong64*) printf 'loong64-abi2' ;;
		*ppc64le*) printf 'ppc64le' ;;
		*s390x*) printf 's390x' ;;
		*) return 1 ;;
	esac
}

shellcrash_architecture() {
	case "$(system_architecture 2>/dev/null)" in
		amd64-compatible) printf 'amd64' ;;
		arm64) printf 'arm64' ;;
		armv5) printf 'armv5' ;;
		armv7) printf 'armv7' ;;
		mips-softfloat) printf 'mips-softfloat' ;;
		mipsle-hardfloat) printf 'mipsle-hardfloat' ;;
		mipsle-softfloat) printf 'mipsle-softfloat' ;;
		*) return 1 ;;
	esac
}

extract_version_token() {
	printf '%s\n' "$1" | sed -n 's/.*\(v[0-9][0-9]*\(\.[0-9][0-9]*\)\{1,3\}\([._+-][0-9A-Za-z._+-]*\)\?\).*/\1/p' | head -n 1
}

official_preset_label() {
	case "$OFFICIAL_PRESET" in
		auto) printf '自动 HTTPS 回退（推荐）' ;;
		proxy) printf 'PROXY 加速（推荐）' ;;
		proxynet) printf 'PROXYNET 加速' ;;
		github) printf 'GitHub 直链' ;;
	esac
}

official_channel_label() {
	case "$1" in
		proxy) printf 'PROXY 加速' ;;
		proxynet) printf 'PROXYNET 加速' ;;
		github) printf 'GitHub 直链' ;;
		*) return 1 ;;
	esac
}

repository_preset_label() {
	case "$REPOSITORY_PRESET" in
		auto) printf 'ShellCrash 自动选择 HTTPS 源' ;;
		cloudflare) printf 'ShellCrash JSdelivr CF（推荐）' ;;
		jsdelivr) printf 'ShellCrash jsDelivr CDN' ;;
		github) printf 'ShellCrash GitHub 直链' ;;
		author_https) printf 'ShellCrash HTTPS 镜像' ;;
		author_http) printf 'ShellCrash HTTP 内测源（不安全）' ;;
		custom) printf 'ShellCrash 自定义兼容仓库' ;;
	esac
}

source_label() {
	case "$SOURCE_TYPE" in
		official)
			if [ -n "$RESOLVED_OFFICIAL_DOWNLOAD_CHANNEL" ]; then
				printf 'MetaCubeX 官方最新发布 · %s' "$(official_channel_label "$RESOLVED_OFFICIAL_DOWNLOAD_CHANNEL")"
			else
				printf 'MetaCubeX 官方最新发布 · %s' "$(official_preset_label)"
			fi
			;;
		repository)
			if [ -n "$RESOLVED_REPOSITORY_BASE" ]; then
				printf '%s: %s' "$(repository_preset_label)" "$RESOLVED_REPOSITORY_BASE"
			else
				printf '%s' "$(repository_preset_label)"
			fi
			;;
		release) printf 'Releases: %s (%s)' "$RELEASES_URL" "$RELEASES_TAG" ;;
		direct) printf '精确直链: %s' "$DIRECT_URL" ;;
	esac
}

repository_bases() {
	case "$REPOSITORY_PRESET" in
		auto)
			printf '%s\n' \
				'https://testingcf.jsdelivr.net/gh/juewuy/ShellCrash@dev' \
				'https://cdn.jsdelivr.net/gh/juewuy/ShellCrash@dev' \
				'https://gh.jwsc.eu.org/dev' \
				'https://raw.githubusercontent.com/juewuy/ShellCrash/dev'
			;;
		cloudflare) printf '%s\n' 'https://testingcf.jsdelivr.net/gh/juewuy/ShellCrash@dev' ;;
		jsdelivr) printf '%s\n' 'https://cdn.jsdelivr.net/gh/juewuy/ShellCrash@dev' ;;
		github) printf '%s\n' 'https://raw.githubusercontent.com/juewuy/ShellCrash/dev' ;;
		author_https) printf '%s\n' 'https://gh.jwsc.eu.org/dev' ;;
		author_http) printf '%s\n' 'http://t.jwsc.eu.org' ;;
		custom) [ -n "$REPOSITORY_URL" ] && printf '%s\n' "$(trim_slash "$REPOSITORY_URL")" ;;
	esac
}

official_download_channels() {
	case "$OFFICIAL_PRESET" in
		auto) printf '%s\n' proxy proxynet github ;;
		proxy) printf '%s\n' proxy ;;
		proxynet) printf '%s\n' proxynet ;;
		github) printf '%s\n' github ;;
	esac
}

official_asset_url() {
	case "$1" in
		proxy) printf 'https://gh-proxy.com/%s' "$2" ;;
		proxynet) printf 'https://ghproxy.net/%s' "$2" ;;
		github) printf '%s' "$2" ;;
		*) return 1 ;;
	esac
}

remaining_seconds() {
	local now remaining
	[ "$UPDATE_DEADLINE" -gt 0 ] || { printf '%s' "$UPDATE_TASK_TIMEOUT"; return; }
	now="$(date +%s)"
	remaining=$((UPDATE_DEADLINE - now))
	[ "$remaining" -gt 0 ] || return 1
	printf '%s' "$remaining"
}

validate_official_release_json() {
	local json_file="$1" tag asset_count
	[ -s "$json_file" ] || return 1
	tag="$("$YQ_BIN" -M -p json -r '.tag_name // ""' "$json_file" 2>/dev/null)"
	asset_count="$("$YQ_BIN" -M -p json -r '.assets | length' "$json_file" 2>/dev/null)"
	[ -n "$tag" ] && [ "$tag" != null ] || return 1
	case "$asset_count" in ''|*[!0-9]*) return 1 ;; esac
	[ "$asset_count" -gt 0 ]
}

fetch_official_release_json() {
	local repository="$1" output="$2" url
	for url in \
		"https://api.github.com/repos/${repository}/releases/latest" \
		"https://gh-proxy.com/https://api.github.com/repos/${repository}/releases/latest"; do
		rm -f "$output"
		if "$CURL_BIN" -fL --connect-timeout "$API_TIMEOUT" --max-time "$API_TIMEOUT" --retry 0 -A "$USER_AGENT" -sS -o "$output" "$url" 2>/dev/null \
			&& validate_official_release_json "$output"; then
			return 0
		fi
	done
	rm -f "$output"
	return 1
}

probe_url() {
	local url="$1" asset="${2:-}" probe bytes first second
	probe="$TEMP_ROOT/nikki-core-probe.$$"
	rm -f "$probe"
	"$CURL_BIN" -fL --range 0-1 --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" --retry 0 -A "$USER_AGENT" -sS -o "$probe" "$url" 2>/dev/null || {
		rm -f "$probe"
		return 1
	}
	[ -s "$probe" ] || { rm -f "$probe"; return 1; }

	case "$asset" in
		*.tar.gz|*.tgz|*.gz)
			bytes="$(od -An -tu1 -N2 "$probe" 2>/dev/null)" || { rm -f "$probe"; return 1; }
			set -- $bytes
			first="${1:-}"
			second="${2:-}"
			rm -f "$probe"
			[ "$first" = 31 ] && [ "$second" = 139 ]
			;;
		*)
			rm -f "$probe"
			return 0
			;;
	esac
}

fetch_text_5s() {
	"$CURL_BIN" -fL --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" --retry 0 -A "$USER_AGENT" -sS "$1" 2>/dev/null
}

resolve_official_source() {
	local json_file tag arch name original channel candidate
	json_file="$TEMP_ROOT/nikki-release.$$.json"
	cleanup_paths="$cleanup_paths $json_file"
	fetch_official_release_json "$OFFICIAL_REPOSITORY" "$json_file" || { ERROR_KIND=network; return 1; }
	tag="$("$YQ_BIN" -M -p json -r '.tag_name // ""' "$json_file" 2>/dev/null)"
	arch="$(system_architecture)" || { ERROR_KIND=arch; return 1; }
	name="mihomo-linux-${arch}-${tag}.gz"
	ASSET_NAME="$name" original="$(ASSET_NAME="$name" "$YQ_BIN" -M -p json -r '.assets[] | select(.name == env(ASSET_NAME)) | .browser_download_url' "$json_file" 2>/dev/null | head -n 1)"
	[ -n "$original" ] && [ "$original" != null ] || { ERROR_KIND=arch; return 1; }
	for channel in $(official_download_channels); do
		candidate="$(official_asset_url "$channel" "$original")" || continue
		if probe_url "$candidate" "$name"; then
			LATEST_VERSION="$tag"
			RESOLVED_ASSET="$name"
			RESOLVED_URL="$candidate"
			RESOLVED_OFFICIAL_DOWNLOAD_CHANNEL="$channel"
			return 0
		fi
	done
	ERROR_KIND=network
	return 1
}

resolve_repository_source() {
	local arch name base text version candidate
	arch="$(shellcrash_architecture)" || { ERROR_KIND=arch; return 1; }
	name="clash-linux-${arch}.tar.gz"
	for base in $(repository_bases); do
		text="$(fetch_text_5s "$(trim_slash "$base")/bin/version")" || continue
		version="$(printf '%s\n' "$text" | sed -n 's/.*meta_v=\([^[:space:]]*\).*/\1/p' | head -n 1)"
		[ -n "$version" ] || version="$(extract_version_token "$text")"
		[ -n "$version" ] || continue
		candidate="$(trim_slash "$base")/bin/meta/$name"
		if probe_url "$candidate" "$name"; then
			LATEST_VERSION="$version"
			RESOLVED_ASSET="$name"
			RESOLVED_URL="$candidate"
			RESOLVED_REPOSITORY_BASE="$(trim_slash "$base")"
			return 0
		fi
	done
	ERROR_KIND=network
	return 1
}

resolve_release_tag() {
	local base="$1" tag="$2" effective
	[ "$tag" = latest ] || { printf '%s' "$tag"; return 0; }
	case "$base" in
		https://github.com/*/releases|http://github.com/*/releases)
			effective="$("$CURL_BIN" -fL --connect-timeout "$API_TIMEOUT" --max-time "$API_TIMEOUT" --retry 0 -A "$USER_AGENT" -sS -o /dev/null -w '%{url_effective}' "$(trim_slash "$base")/latest" 2>/dev/null)"
			tag="${effective##*/}"
			[ -n "$tag" ] && [ "$tag" != latest ] && { printf '%s' "$tag"; return 0; }
			;;
	esac
	printf 'latest'
}

resolve_release_source() {
	local base tag arch name path candidate
	[ -n "$RELEASES_URL" ] || { ERROR_KIND=network; return 1; }
	arch="$(system_architecture)" || { ERROR_KIND=arch; return 1; }
	base="$(trim_slash "$RELEASES_URL")"
	tag="$(resolve_release_tag "$base" "$RELEASES_TAG")"
	name="mihomo-linux-${arch}-${tag}.gz"
	case "$base" in
		https://github.com/*/releases|http://github.com/*/releases) path="download/$tag/$name" ;;
		*) path="$tag/$name" ;;
	esac
	candidate="$base/$path"
	probe_url "$candidate" "$name" || { ERROR_KIND=network; return 1; }
	LATEST_VERSION="$tag"
	RESOLVED_ASSET="$name"
	RESOLVED_URL="$candidate"
	return 0
}

resolve_direct_source() {
	local asset
	[ -n "$DIRECT_URL" ] || { ERROR_KIND=network; return 1; }
	asset="${DIRECT_URL%%\?*}"
	asset="${asset##*/}"
	probe_url "$DIRECT_URL" "$asset" || { ERROR_KIND=network; return 1; }
	LATEST_VERSION="$(extract_version_token "$DIRECT_URL")"
	[ -n "$LATEST_VERSION" ] || LATEST_VERSION=unknown
	RESOLVED_URL="$DIRECT_URL"
	RESOLVED_ASSET="$asset"
	return 0
}

resolve_source() {
	RESOLVED_OFFICIAL_DOWNLOAD_CHANNEL=
	RESOLVED_REPOSITORY_BASE=
	RESOLVED_URL=
	RESOLVED_ASSET=
	LATEST_VERSION=
	ERROR_KIND=
	case "$SOURCE_TYPE" in
		official) resolve_official_source ;;
		repository) resolve_repository_source ;;
		release) resolve_release_source ;;
		direct) resolve_direct_source ;;
	esac
}

save_resolved_state() {
	state_set latest_version "$LATEST_VERSION"
	state_set checked_source_key "$(source_key)"
	state_set source "$(source_label)"
}

check_source() {
	acquire_lock || return 1
	load_config
	state_set source "$(source_label)"
	state_set latest_version ''
	set_status checking ''
	if resolve_source; then
		save_resolved_state
		set_status checked ''
		printf '%s\n' "$LATEST_VERSION"
		return 0
	fi
	state_set checked_source_key "$(source_key)"
	state_set latest_version ''
	state_set source "$(source_label)"
	fail '暂无法连接当前更新源，请重试几次或更换源'
}

available_kb() {
	df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4; exit }'
}

mem_available_kb() {
	local mem tmp
	mem="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	tmp="$(available_kb "$TEMP_ROOT")"
	case "$mem" in ''|*[!0-9]*) mem=0 ;; esac
	case "$tmp" in ''|*[!0-9]*) tmp=0 ;; esac
	[ "$tmp" -lt "$mem" ] && printf '%s' "$tmp" || printf '%s' "$mem"
}

core_exists() {
	[ -e "$CORE_ACTIVE" ] || [ -L "$CORE_ACTIVE" ]
}

firmware_core_path() {
	local path
	for path in /usr/libexec/mihomo /usr/bin/mihomo; do
		[ -x "$path" ] && { printf '%s' "$path"; return 0; }
	done
	return 1
}

ensure_active_core() {
	local firmware
	mkdir -p "$CORE_DIR" || return 1
	if [ -L "$CORE_ACTIVE" ] && [ ! -e "$CORE_ACTIVE" ]; then
		rm -f "$CORE_ACTIVE"
	fi
	core_exists && return 0
	firmware="$(firmware_core_path)" || return 0
	ln -s "$firmware" "$CORE_ACTIVE" || return 1
}

core_origin() {
	local target
	if ! core_exists; then
		printf 'none'
		return
	fi
	if [ -L "$CORE_ACTIVE" ]; then
		target="$(readlink "$CORE_ACTIVE" 2>/dev/null)"
		case "$target" in /usr/libexec/mihomo|/usr/bin/mihomo) printf 'firmware'; return ;; esac
	fi
	printf 'downloaded'
}

core_size_bytes() {
	[ "$(core_origin)" = downloaded ] || { printf '0'; return; }
	wc -c < "$CORE_ACTIVE" 2>/dev/null | tr -d ' '
}

choose_download_root() {
	local has_core="$1" disk mem
	disk="$(available_kb "$CORE_DIR")"
	mem="$(mem_available_kb)"
	case "$disk" in ''|*[!0-9]*) disk=0 ;; esac
	case "$mem" in ''|*[!0-9]*) mem=0 ;; esac
	DOWNLOAD_PREDELETE=0
	if [ "$has_core" -eq 0 ]; then
		[ "$disk" -ge $((50 * MIB_KB)) ] || return 1
		if [ "$disk" -ge $((70 * MIB_KB)) ]; then
			DOWNLOAD_ROOT="$CORE_DIR"
		elif [ "$mem" -gt $((25 * MIB_KB)) ]; then
			DOWNLOAD_ROOT="$TEMP_ROOT"
		else
			return 1
		fi
	else
		if [ "$disk" -lt $((20 * MIB_KB)) ] && [ "$mem" -lt $((20 * MIB_KB)) ]; then
			return 1
		fi
		if [ "$disk" -ge $((30 * MIB_KB)) ]; then
			DOWNLOAD_ROOT="$CORE_DIR"
		elif [ "$mem" -ge $((20 * MIB_KB)) ]; then
			DOWNLOAD_ROOT="$TEMP_ROOT"
		else
			# The disk itself meets the agreed 20 MiB boundary but cannot hold
			# the old core and archive together. Remove the old core first.
			DOWNLOAD_ROOT="$CORE_DIR"
			DOWNLOAD_PREDELETE=1
		fi
	fi
	return 0
}

service_running() {
	[ -x "$SERVICE_BIN" ] || return 1
	"$SERVICE_BIN" running >/dev/null 2>&1
}

stop_service() {
	[ -x "$SERVICE_BIN" ] || return 0
	"$SERVICE_BIN" stop >/dev/null 2>&1 || :
}

wait_service_stopped() {
	local seconds="${1:-5}"
	while [ "$seconds" -gt 0 ]; do
		service_running || return 0
		sleep 1
		seconds=$((seconds - 1))
	done
	! service_running
}

restart_service_checked() {
	[ -x "$SERVICE_BIN" ] || return 0
	"$SERVICE_BIN" restart >/dev/null 2>&1 || return 1
	sleep 2
	service_running
}

download_resolved() {
	local output="$1" partial remaining attempt
	partial="${output}.part"
	cleanup_paths="$cleanup_paths $partial"
	attempt=1
	rm -f "$output" "$partial"
	while [ "$attempt" -le "$DOWNLOAD_ATTEMPTS" ]; do
		remaining="$(remaining_seconds)" || { rm -f "$partial"; return 1; }
		if "$CURL_BIN" -fL \
			--connect-timeout "$NO_RESPONSE_TIMEOUT" \
			--speed-limit 1 --speed-time "$NO_RESPONSE_TIMEOUT" \
			--max-time "$remaining" --retry 0 \
			-A "$USER_AGENT" -sS -o "$partial" "$RESOLVED_URL" 2>/dev/null \
			&& [ -s "$partial" ]; then
			mv -f "$partial" "$output" || { rm -f "$partial"; return 1; }
			return 0
		fi
		rm -f "$partial"
		attempt=$((attempt + 1))
		[ "$attempt" -le "$DOWNLOAD_ATTEMPTS" ] && sleep 2
	done
	return 1
}

detect_download_kind() {
	local archive="$1" bytes first second
	[ -s "$archive" ] || return 1

	# A gzip-compressed tar archive must be checked before a plain .gz stream.
	if tar -tzf "$archive" >/dev/null 2>&1; then
		printf '%s' tar_gz
		return 0
	fi

	bytes="$(od -An -tu1 -N2 "$archive" 2>/dev/null)" || return 1
	set -- $bytes
	first="${1:-}"
	second="${2:-}"
	if [ "$first" = 31 ] && [ "$second" = 139 ]; then
		gzip -t "$archive" >/dev/null 2>&1 || return 1
		printf '%s' gzip
		return 0
	fi

	is_elf_file "$archive" || return 1
	printf '%s' elf
}

validate_download_file() {
	detect_download_kind "$1" >/dev/null
}

extract_to_active() {
	local archive="$1" asset="$2" kind list_file item selected fallback
	kind="$(detect_download_kind "$archive")" || return 1
	rm -f "$CORE_ACTIVE" || return 1
	case "$kind" in
		tar_gz)
			list_file="$TEMP_ROOT/nikki-core-list.$$"
			cleanup_paths="$cleanup_paths $list_file"
			tar -tzf "$archive" > "$list_file" 2>/dev/null || return 1
			selected=
			fallback=
			while IFS= read -r item; do
				[ -n "$item" ] || continue
				case "$item" in /*|../*|*/../*|*/..|-*|*/-*) return 1 ;; */) continue ;; esac
				[ -n "$fallback" ] || fallback="$item"
				case "${item##*/}" in mihomo|mihomo-*|clash|clash-*) selected="$item"; break ;; esac
			done < "$list_file"
			[ -n "$selected" ] || selected="$fallback"
			[ -n "$selected" ] || return 1
			tar -xOzf "$archive" "$selected" > "$CORE_ACTIVE" 2>/dev/null || return 1
			;;
		gzip)
			gzip -dc "$archive" > "$CORE_ACTIVE" 2>/dev/null || return 1
			;;
		elf)
			cp "$archive" "$CORE_ACTIVE" || return 1
			;;
		*) return 1 ;;
	esac
	[ -s "$CORE_ACTIVE" ] || return 1
}

is_elf_file() {
	local path="$1" bytes
	bytes="$(od -An -tu1 -N4 "$path" 2>/dev/null)" || return 1
	set -- $bytes
	[ "${1:-}" = 127 ] && [ "${2:-}" = 69 ] && [ "${3:-}" = 76 ] && [ "${4:-}" = 70 ]
}

validate_installed_core() {
	local version
	[ -f "$CORE_ACTIVE" ] && [ -s "$CORE_ACTIVE" ] || return 1
	chmod 0755 "$CORE_ACTIVE" || return 1
	version="$(core_version "$CORE_ACTIVE")"
	[ -n "$version" ] || return 1
	printf '%s' "$version"
}

update_core_locked() {
	local has_core was_running archive installed_version
	load_config
	ensure_active_core || { fail '空间不足，请自行释放空间后重试'; return 1; }
	has_core=0
	core_exists && has_core=1
	choose_download_root "$has_core" || { fail '空间不足，请自行释放空间后重试'; return 1; }
	UPDATE_DEADLINE=$(( $(date +%s) + UPDATE_TASK_TIMEOUT ))
	state_set source "$(source_label)"
	state_set latest_version ''
	state_set checked_source_key "$(source_key)"
	set_status updating ''

	resolve_source || {
		case "$ERROR_KIND" in
			arch) fail '无法从当前更新源找到适配本机的内核' ;;
			*) fail '暂无法连接当前更新源，请重试几次或更换源' ;;
		esac
		return 1
	}
	save_resolved_state
	set_status updating ''

	was_running=0
	service_running && was_running=1
	if [ "$DOWNLOAD_PREDELETE" -eq 1 ]; then
		[ "$was_running" -eq 0 ] || { stop_service; wait_service_stopped 5 || :; }
		rm -f "$CORE_ACTIVE"
		has_core=0
	fi

	archive="$DOWNLOAD_ROOT/.nikki-core-download.$$"
	cleanup_paths="$cleanup_paths $archive"
	if ! download_resolved "$archive"; then
		rm -f "$archive"
		fail '暂无法连接当前更新源，请重试几次或更换源'
		return 1
	fi
	if ! validate_download_file "$archive" "$RESOLVED_ASSET"; then
		rm -f "$archive"
		fail '更新源返回的不是有效内核文件，请更换更新源后重试'
		return 1
	fi

	if [ "$has_core" -eq 1 ]; then
		[ "$was_running" -eq 0 ] || { stop_service; wait_service_stopped 5 || :; }
		sleep 2
		rm -f "$CORE_ACTIVE"
	fi

	if ! extract_to_active "$archive" "$RESOLVED_ASSET"; then
		rm -f "$archive" "$CORE_ACTIVE"
		fail '下载的内核文件已损坏'
		return 1
	fi
	rm -f "$archive"

	installed_version="$(validate_installed_core)" || {
		rm -f "$CORE_ACTIVE"
		fail '下载的内核文件已损坏'
		return 1
	}

	if [ "$was_running" -eq 1 ] && ! restart_service_checked; then
		stop_service
		rm -f "$CORE_ACTIVE"
		fail '新内核安装完成，但服务启动失败'
		return 1
	fi

	state_set latest_version "$installed_version"
	state_set installed_version "$installed_version"
	state_set checked_source_key "$(source_key)"
	state_set source "$(source_label)"
	set_status success ''
	printf '%s\n' "$installed_version"
}

update_core() {
	acquire_lock || return 1
	update_core_locked
}

start_update() {
	local worker
	acquire_lock || return 1
	load_config
	state_set checked_source_key "$(source_key)"
	state_set source "$(source_label)"
	state_set latest_version ''
	set_status updating ''
	(
		local rc
		lock_held=1
		trap cleanup EXIT INT TERM
		if command -v timeout >/dev/null 2>&1; then
			timeout -s TERM "$UPDATE_TASK_TIMEOUT" "$0" update-worker >/dev/null 2>&1
			rc=$?
		else
			update_core_locked >/dev/null 2>&1
			rc=$?
		fi
		if [ "$rc" -ne 0 ] && [ "$(state_get last_status)" = updating ]; then
			fail '暂无法连接当前更新源，请重试几次或更换源' >/dev/null 2>&1 || :
		fi
		exit "$rc"
	) >/dev/null 2>&1 &
	worker=$!
	printf '%s\n' "$worker" > "$LOCK_DIR/pid" 2>/dev/null || :
	lock_held=0
	printf '%s\n' "$worker"
}

delete_current_core() {
	local origin bytes mib was_running
	acquire_lock || return 1
	ensure_active_core || :
	origin="$(core_origin)"
	case "$origin" in
		firmware)
			set_status core_deleted '当前为固件内置核心，不占用可写空间，无法通过删除释放更新空间'
			return 0
			;;
		none)
			set_status core_deleted '当前没有可删除的内核'
			return 0
			;;
	esac
	bytes="$(core_size_bytes)"
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	was_running=0
	service_running && was_running=1
	[ "$was_running" -eq 0 ] || { stop_service; wait_service_stopped 5 || :; }
	rm -f "$CORE_ACTIVE" "$CORE_DIR"/.mihomo.* "$CORE_DIR"/.nikki-core-download.* "$TEMP_ROOT"/.nikki-core-download.* 2>/dev/null || {
		fail '删除当前内核失败'
		return 1
	}
	mib=$(( (bytes + 524288) / 1048576 ))
	state_set installed_version ''
	state_set latest_version ''
	set_status core_deleted "当前内核已删除，已释放约 ${mib} MiB 空间"
}

print_status() {
	local package uname_arch active latest source status error updated current_key checked_key origin size
	load_config
	ensure_active_core >/dev/null 2>&1 || :
	package="$(package_architecture)"
	uname_arch="$("$UNAME_BIN" -m 2>/dev/null)"
	active="$(core_version "$CORE_ACTIVE")"
	latest="$(state_get latest_version)"
	source="$(state_get source)"
	status="$(state_get last_status)"; [ -n "$status" ] || status=idle
	error="$(state_get last_error)"
	updated="$(state_get last_update)"
	current_key="$(source_key)"
	checked_key="$(state_get checked_source_key)"
	if [ -n "$checked_key" ] && [ "$current_key" != "$checked_key" ]; then
		latest=
		source="$(source_label)"
		status=source_changed
		error=
		updated=
	elif [ -z "$source" ]; then
		source="$(source_label)"
	fi
	origin="$(core_origin)"
	size="$(core_size_bytes)"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	printf 'architecture_uname\t%s\n' "$(single_line "$uname_arch")"
	printf 'architecture_package\t%s\n' "$(single_line "$package")"
	printf 'current_version\t%s\n' "$(single_line "$active")"
	printf 'latest_version\t%s\n' "$(single_line "$latest")"
	printf 'source\t%s\n' "$(single_line "$source")"
	printf 'status\t%s\n' "$(single_line "$status")"
	printf 'error\t%s\n' "$(single_line "$error")"
	printf 'updated_at\t%s\n' "$(single_line "$updated")"
	printf 'core_origin\t%s\n' "$origin"
	printf 'core_size_bytes\t%s\n' "$size"
	printf 'active_path\t%s\n' "$CORE_ACTIVE"
}

migrate_core() {
	mkdir -p "$CORE_DIR" || return 1
	rm -f "$CORE_DIR/mihomo.prev" "$CORE_DIR"/.mihomo.update.* "$CORE_DIR"/.mihomo.rollback.* 2>/dev/null || :
	ensure_active_core
}

case "${1:-status}" in
	status) print_status ;;
	check) check_source ;;
	update) update_core ;;
	update-worker) update_core_locked ;;
	start-update) start_update ;;
	delete-current) delete_current_core ;;
	migrate) migrate_core ;;
	architectures) printf 'official\t%s\n' "$(system_architecture 2>/dev/null)"; printf 'shellcrash\t%s\n' "$(shellcrash_architecture 2>/dev/null)" ;;
	*) printf 'Usage: %s {status|check|update|update-worker|start-update|delete-current|migrate|architectures}\n' "$0" >&2; exit 2 ;;
esac
