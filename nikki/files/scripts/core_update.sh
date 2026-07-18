#!/bin/sh

# Nikki Legacy Mihomo two-slot core updater.
# BusyBox/ash compatible; no ucode, firewall4 or nftables dependency.

HOME_DIR="${HOME_DIR:-/etc/nikki}"
CORE_DIR="${CORE_DIR:-/usr/libexec/nikki}"
CORE_ACTIVE="${CORE_ACTIVE:-$CORE_DIR/mihomo}"
CORE_PREVIOUS="${CORE_PREVIOUS:-$CORE_DIR/mihomo.prev}"
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

SOURCE_TYPE=official
OFFICIAL_REPOSITORY=MetaCubeX/mihomo
REPOSITORY_PRESET=auto
REPOSITORY_URL=
RESOLVED_REPOSITORY_BASE=
RELEASES_URL=https://github.com/MetaCubeX/mihomo/releases
RELEASES_TAG=latest
DIRECT_URL=
USER_AGENT=nikki-core-updater
DOWNLOAD_TIMEOUT=120
DOWNLOAD_RETRY=2
MIN_FREE_KB=32768

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
	fail "已有内核更新任务正在运行"
}

uci_get() {
	"$UCI_BIN" -q get "$1" 2>/dev/null
}

load_config() {
	local value preset_configured
	value="$(uci_get nikki.core_update.source_type)"; [ -n "$value" ] && SOURCE_TYPE="$value"
	value="$(uci_get nikki.core_update.official_repository)"; [ -n "$value" ] && OFFICIAL_REPOSITORY="$value"
	preset_configured="$(uci_get nikki.core_update.repository_preset)"
	value="$(uci_get nikki.core_update.repository_url)"; [ -n "$value" ] && REPOSITORY_URL="$value"
	if [ -n "$preset_configured" ]; then
		REPOSITORY_PRESET="$preset_configured"
	elif [ -n "$REPOSITORY_URL" ]; then
		# Backward compatibility with legacy5, where repository_url was the
		# only ShellCrash-compatible source field.
		REPOSITORY_PRESET=custom
	fi
	value="$(uci_get nikki.core_update.releases_url)"; [ -n "$value" ] && RELEASES_URL="$value"
	value="$(uci_get nikki.core_update.releases_tag)"; [ -n "$value" ] && RELEASES_TAG="$value"
	value="$(uci_get nikki.core_update.direct_url)"; [ -n "$value" ] && DIRECT_URL="$value"
	value="$(uci_get nikki.core_update.user_agent)"; [ -n "$value" ] && USER_AGENT="$value"
	value="$(uci_get nikki.core_update.timeout)"; [ -n "$value" ] && DOWNLOAD_TIMEOUT="$value"
	value="$(uci_get nikki.core_update.retry)"; [ -n "$value" ] && DOWNLOAD_RETRY="$value"
	value="$(uci_get nikki.core_update.min_free_kb)"; [ -n "$value" ] && MIN_FREE_KB="$value"

	case "$SOURCE_TYPE" in official|repository|release|direct) ;; *) SOURCE_TYPE=official ;; esac
	case "$REPOSITORY_PRESET" in auto|cloudflare|jsdelivr|github|author_https|author_http|custom) ;; *) REPOSITORY_PRESET=auto ;; esac
	case "$DOWNLOAD_TIMEOUT" in ''|*[!0-9]*|0) DOWNLOAD_TIMEOUT=120 ;; esac
	case "$DOWNLOAD_RETRY" in ''|*[!0-9]*) DOWNLOAD_RETRY=2 ;; esac
	case "$MIN_FREE_KB" in ''|*[!0-9]*) MIN_FREE_KB=32768 ;; esac
}

core_version() {
	local path="$1" output version
	[ -x "$path" ] || return 0
	output="$("$path" -v 2>/dev/null | head -n 2)"
	version="$(printf '%s\n' "$output" | sed -n 's/.*\(v[0-9][0-9A-Za-z._+-]*\).*/\1/p' | head -n 1)"
	[ -n "$version" ] || version="$(printf '%s\n' "$output" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^(alpha-|meta-)?[0-9]/) { print $i; exit } }')"
	printf '%s' "$version"
}

core_identity() {
	local path="$1" identity
	[ -e "$path" ] || return 0
	if command -v stat >/dev/null 2>&1; then
		identity="$(stat -c '%s:%Y' "$path" 2>/dev/null)"
	fi
	[ -n "$identity" ] || identity="$(wc -c < "$path" 2>/dev/null)"
	printf '%s' "$identity"
}

clear_core_version_cache() {
	local slot="$1"
	state_set "${slot}_version" '' >/dev/null 2>&1 || :
	state_set "${slot}_identity" '' >/dev/null 2>&1 || :
}

cache_core_version() {
	local slot="$1" path="$2" version="$3" identity
	[ -n "$version" ] || { clear_core_version_cache "$slot"; return 0; }
	identity="$(core_identity "$path")"
	state_set "${slot}_version" "$version" >/dev/null 2>&1 || :
	state_set "${slot}_identity" "$identity" >/dev/null 2>&1 || :
}

cached_core_version() {
	local slot="$1" path="$2" identity cached_identity version
	if [ ! -x "$path" ]; then
		[ -n "$(state_get "${slot}_version")$(state_get "${slot}_identity")" ] && clear_core_version_cache "$slot"
		return 0
	fi

	identity="$(core_identity "$path")"
	cached_identity="$(state_get "${slot}_identity")"
	version="$(state_get "${slot}_version")"
	if [ -n "$version" ] && [ -n "$identity" ] && [ "$cached_identity" = "$identity" ]; then
		printf '%s' "$version"
		return 0
	fi

	version="$(core_version "$path")"
	if [ -n "$version" ]; then
		cache_core_version "$slot" "$path" "$version"
	else
		clear_core_version_cache "$slot"
	fi
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

append_unique() {
	local list="$1" item="$2"
	[ -n "$item" ] || { printf '%s' "$list"; return; }
	case " $list " in *" $item "*) printf '%s' "$list" ;; *) printf '%s%s%s' "$list" "${list:+ }" "$item" ;; esac
}

architecture_candidates() {
	local package uname_arch candidates normalized
	package="$(package_architecture)"
	uname_arch="$("$UNAME_BIN" -m 2>/dev/null)"
	candidates=

	for normalized in "$package" "$uname_arch"; do
		[ -n "$normalized" ] || continue
		candidates="$(append_unique "$candidates" "$normalized")"
		candidates="$(append_unique "$candidates" "$(printf '%s' "$normalized" | tr '_' '-')")"
	done

	case "$package:$uname_arch" in
		*aarch64*|*arm64*)
			candidates="$(append_unique "$candidates" aarch64)"
			candidates="$(append_unique "$candidates" arm64)"
			;;
		*arm_cortex-a5*|*arm_cortex-a7*|*arm_cortex-a8*|*arm_cortex-a9*|*arm_cortex-a15*|*armv7*)
			candidates="$(append_unique "$candidates" armv7)"
			candidates="$(append_unique "$candidates" arm32v7)"
			;;
		*armv6*)
			candidates="$(append_unique "$candidates" armv6)"
			candidates="$(append_unique "$candidates" arm32v6)"
			;;
		*x86_64*|*amd64*)
			candidates="$(append_unique "$candidates" x86_64)"
			candidates="$(append_unique "$candidates" amd64)"
			candidates="$(append_unique "$candidates" amd64-v1)"
			;;
		*i386*|*i486*|*i586*|*i686*|*x86*)
			candidates="$(append_unique "$candidates" 386)"
			;;
		*mipsel*|*mipsle*)
			candidates="$(append_unique "$candidates" mipsel)"
			candidates="$(append_unique "$candidates" mipsle)"
			candidates="$(append_unique "$candidates" mipsle-softfloat)"
			;;
		*mips*)
			candidates="$(append_unique "$candidates" mips)"
			candidates="$(append_unique "$candidates" mips-softfloat)"
			;;
		*riscv64*) candidates="$(append_unique "$candidates" riscv64)" ;;
		*loongarch64*|*loong64*) candidates="$(append_unique "$candidates" loong64)" ;;
	esac
	printf '%s\n' $candidates
}

asset_names() {
	local version="$1" prefix arch base suffix
	for prefix in mihomo clash; do
		for arch in $(architecture_candidates); do
			base="${prefix}-linux-${arch}"
			if [ -n "$version" ] && [ "$version" != latest ] && [ "$version" != unknown ]; then
				for suffix in tar.gz tgz gz ''; do
					[ -n "$suffix" ] && printf '%s-%s.%s\n' "$base" "$version" "$suffix" || printf '%s-%s\n' "$base" "$version"
				done
			fi
			for suffix in tar.gz tgz gz ''; do
				[ -n "$suffix" ] && printf '%s.%s\n' "$base" "$suffix" || printf '%s\n' "$base"
			done
		done
	done
}

repository_bases() {
	# Source IDs 101-104 and 202 from ShellCrash public/servers_chs.list.
	# Each HTTPS base is normalized to the dev tree that contains bin/version
	# and bin/meta/. The plaintext HTTP beta source is never used by auto mode.
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

repository_preset_label() {
	case "$REPOSITORY_PRESET" in
		auto) printf 'ShellCrash 自动选择 HTTPS 源' ;;
		cloudflare) printf 'ShellCrash Cloudflare jsDelivr' ;;
		jsdelivr) printf 'ShellCrash jsDelivr CDN' ;;
		github) printf 'ShellCrash GitHub Raw' ;;
		author_https) printf 'ShellCrash 作者 HTTPS 源' ;;
		author_http) printf 'ShellCrash 作者 HTTP 内测源' ;;
		custom) printf 'ShellCrash 自定义兼容仓库' ;;
	esac
}

source_label() {
	case "$SOURCE_TYPE" in
		official) printf 'MetaCubeX/mihomo official releases' ;;
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

curl_common() {
	"$CURL_BIN" -fL --connect-timeout 10 --max-time "$DOWNLOAD_TIMEOUT" --retry "$DOWNLOAD_RETRY" -A "$USER_AGENT" "$@"
}

fetch_text() {
	curl_common -sS "$1" 2>/dev/null
}

extract_version_token() {
	printf '%s\n' "$1" | sed -n 's/.*\(v[0-9][0-9]*\(\.[0-9][0-9]*\)\{1,3\}\([._+-][0-9A-Za-z._+-]*\)\?\).*/\1/p' | head -n 1
}

resolve_github_latest_tag() {
	local repository="$1" json tag
	json="$(fetch_text "https://api.github.com/repos/${repository}/releases/latest")" || return 1
	tag="$(printf '%s' "$json" | "$YQ_BIN" -M -p json -r '.tag_name // ""' 2>/dev/null)"
	[ -n "$tag" ] && [ "$tag" != null ] || return 1
	printf '%s' "$tag"
}

resolve_release_tag() {
	local base="$1" tag="$2" effective
	[ "$tag" = latest ] || { printf '%s' "$tag"; return 0; }
	case "$base" in
		https://github.com/*/releases|http://github.com/*/releases)
			effective="$(curl_common -sS -o /dev/null -w '%{url_effective}' "$(trim_slash "$base")/latest" 2>/dev/null)"
			tag="${effective##*/}"
			[ -n "$tag" ] && [ "$tag" != latest ] && { printf '%s' "$tag"; return 0; }
			;;
	esac
	printf 'latest'
}

resolve_repository_version() {
	local base text version path
	base="$(trim_slash "$1")"
	# ShellCrash-compatible mirrors publish core metadata in bin/version,
	# commonly as: meta_v=v1.19.x ... . Parse it as data; never source it.
	for path in bin/version version version.txt latest/version latest/version.txt; do
		text="$(fetch_text "$base/$path")" || continue
		version="$(printf '%s\n' "$text" | sed -n 's/.*meta_v=\([^[:space:]]*\).*/\1/p' | head -n 1)"
		[ -n "$version" ] || version="$(extract_version_token "$text")"
		[ -n "$version" ] && { printf '%s' "$version"; return 0; }
	done
	return 1
}

check_source() {
	local latest base found
	load_config
	case "$SOURCE_TYPE" in
		official)
			latest="$(resolve_github_latest_tag "$OFFICIAL_REPOSITORY")" || return 1
			;;
		repository)
			found=0
			for base in $(repository_bases); do
				if latest="$(resolve_repository_version "$base")"; then
					RESOLVED_REPOSITORY_BASE="$base"
					found=1
					break
				fi
				# A custom compatible repository may intentionally omit bin/version.
				if [ "$REPOSITORY_PRESET" = custom ]; then
					latest=latest
					RESOLVED_REPOSITORY_BASE="$base"
					found=1
					break
				fi
			done
			[ "$found" -eq 1 ] || return 1
			;;
		release)
			[ -n "$RELEASES_URL" ] || return 1
			latest="$(resolve_release_tag "$RELEASES_URL" "$RELEASES_TAG")"
			;;
		direct)
			[ -n "$DIRECT_URL" ] || return 1
			latest="$(extract_version_token "$DIRECT_URL")"
			[ -n "$latest" ] || latest=unknown
			;;
	esac
	state_set latest_version "$latest"
	state_set resolved_repository_base "$RESOLVED_REPOSITORY_BASE"
	state_set resolved_url ''
	state_set resolved_asset ''
	state_set source "$(source_label)"
	state_set last_status checked
	state_set last_error ''
	state_set last_update "$(date '+%Y-%m-%d %H:%M:%S')"
	printf '%s\n' "$latest"
}

find_official_asset() {
	local tag="$1" json_file="$2" name url
	for name in $(asset_names "$tag"); do
		ASSET_NAME="$name" url="$(ASSET_NAME="$name" "$YQ_BIN" -M -p json -r '.assets[] | select(.name == env(ASSET_NAME)) | .browser_download_url' "$json_file" 2>/dev/null | head -n 1)"
		[ -n "$url" ] && [ "$url" != null ] && { printf '%s\t%s\n' "$url" "$name"; return 0; }
	done
	return 1
}

try_download() {
	local url="$1" output="$2"
	# curl may leave a partial file after a failed mirror. Never let a later
	# success test reuse bytes from an earlier attempt.
	rm -f "$output"
	curl_common -sS -o "$output" "$url" 2>/dev/null
}

resolve_and_download() {
	local output="$1" latest base tag name url pair json_file path paths found prefix arch suffix
	load_config
	case "$SOURCE_TYPE" in
		official)
			latest="$(resolve_github_latest_tag "$OFFICIAL_REPOSITORY")" || return 1
			json_file="$TEMP_ROOT/nikki-release.$$.json"
			cleanup_paths="$cleanup_paths $json_file"
			fetch_text "https://api.github.com/repos/${OFFICIAL_REPOSITORY}/releases/latest" > "$json_file" || return 1
			pair="$(find_official_asset "$latest" "$json_file")" || return 1
			url="$(printf '%s' "$pair" | cut -f1)"
			name="$(printf '%s' "$pair" | cut -f2-)"
			try_download "$url" "$output" || return 1
			;;
		repository)
			found=0
			for base in $(repository_bases); do
				latest="$(resolve_repository_version "$base")" || {
					[ "$REPOSITORY_PRESET" = custom ] || continue
					latest=latest
				}
				# Native ShellCrash layout first:
				#   <base>/bin/meta/{mihomo|clash}-linux-<arch>.<format>
				for prefix in mihomo clash; do
					for arch in $(architecture_candidates); do
						for suffix in tar.gz tgz gz ''; do
							[ -n "$suffix" ] && name="${prefix}-linux-${arch}.${suffix}" || name="${prefix}-linux-${arch}"
							for path in "bin/meta/$name" "bin/mihomo/$name" "$latest/$name" "latest/$name" "$name"; do
								url="$base/$path"
								if try_download "$url" "$output"; then
									RESOLVED_REPOSITORY_BASE="$base"
									found=1
									break
								fi
							done
							[ "$found" -eq 1 ] && break
						done
						[ "$found" -eq 1 ] && break
					done
					[ "$found" -eq 1 ] && break
				done
				[ "$found" -eq 1 ] && break
			done
			[ "$found" -eq 1 ] || return 1
			;;
		release)
			[ -n "$RELEASES_URL" ] || return 1
			base="$(trim_slash "$RELEASES_URL")"
			tag="$(resolve_release_tag "$base" "$RELEASES_TAG")"
			latest="$tag"
			found=0
			for name in $(asset_names "$tag"); do
				case "$base" in
					https://github.com/*/releases|http://github.com/*/releases)
						paths="download/$tag/$name $tag/$name"
						;;
					*)
						paths="$tag/$name download/$tag/$name"
						;;
				esac
				for path in $paths; do
					url="$base/$path"
					if try_download "$url" "$output"; then found=1; break; fi
				done
				[ "$found" -eq 1 ] && break
			done
			[ -s "$output" ] || return 1
			;;
		direct)
			[ -n "$DIRECT_URL" ] || return 1
			latest="$(extract_version_token "$DIRECT_URL")"
			[ -n "$latest" ] || latest=unknown
			url="$DIRECT_URL"
			name="${DIRECT_URL%%\?*}"; name="${name##*/}"
			try_download "$url" "$output" || return 1
			;;
	esac
	state_set latest_version "$latest"
	state_set resolved_repository_base "$RESOLVED_REPOSITORY_BASE"
	state_set source "$(source_label)"
	state_set resolved_url "$url"
	state_set resolved_asset "$name"
	return 0
}

available_kb() {
	df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4; exit }'
}

check_minimum_space() {
	local path="$1" required="$2" available
	available="$(available_kb "$path")"
	case "$available" in ''|*[!0-9]*) return 0 ;; esac
	[ "$available" -ge "$required" ]
}

extract_candidate() {
	local archive="$1" destination="$2" list_file item selected fallback
	if gzip -t "$archive" >/dev/null 2>&1; then
		if tar -tzf "$archive" >/dev/null 2>&1; then
			list_file="$TEMP_ROOT/nikki-core-list.$$"
			tar -tzf "$archive" > "$list_file" || return 1
			cleanup_paths="$cleanup_paths $list_file"
			selected=
			fallback=
			while IFS= read -r item; do
				[ -n "$item" ] || continue
				case "$item" in
					/*|../*|*/../*|*/..|-*|*/-*) return 1 ;;
					*/) continue ;;
				esac
				[ -n "$fallback" ] || fallback="$item"
				case "${item##*/}" in
					mihomo|mihomo-*|clash|clash-*) selected="$item"; break ;;
				esac
			done < "$list_file"
			[ -n "$selected" ] || selected="$fallback"
			[ -n "$selected" ] || return 1
			# Stream only the selected member. Never unpack an untrusted release
			# archive into the filesystem, even inside a temporary directory.
			tar -xOzf "$archive" "$selected" > "$destination" || return 1
		else
			gzip -dc "$archive" > "$destination" || return 1
		fi
	else
		cp "$archive" "$destination" || return 1
	fi
	chmod 755 "$destination" || return 1
}

validate_candidate() {
	local path="$1" size version
	size="$(wc -c < "$path" 2>/dev/null)"
	case "$size" in ''|*[!0-9]*) return 1 ;; esac
	[ "$size" -ge 262144 ] || return 1
	version="$(core_version "$path")"
	[ -n "$version" ] || return 1
	printf '%s' "$version"
}

service_running() {
	[ -x "$SERVICE_BIN" ] || return 1
	"$SERVICE_BIN" running >/dev/null 2>&1
}

restart_service() {
	[ -x "$SERVICE_BIN" ] || return 0
	"$SERVICE_BIN" restart >/dev/null 2>&1
}

ensure_active_core() {
	local legacy
	mkdir -p "$CORE_DIR" || return 1
	[ -x "$CORE_ACTIVE" ] && return 0
	for legacy in /usr/libexec/mihomo /usr/bin/mihomo; do
		[ -x "$legacy" ] || continue
		case "$legacy" in "$CORE_ACTIVE"|"$CORE_PREVIOUS") continue ;; esac
		cp "$legacy" "$CORE_ACTIVE" || return 1
		chmod 755 "$CORE_ACTIVE" || return 1
		return 0
	done
	return 0
}

install_candidate() {
	local candidate="$1" candidate_version="$2" required_kb active_size previous_size candidate_size extra_slot_bytes was_running
	local new_path active_backup previous_backup previous_new restore_active restore_previous active_existed previous_existed
	mkdir -p "$CORE_DIR" || return 1
	active_size=0
	[ -f "$CORE_ACTIVE" ] && active_size="$(wc -c < "$CORE_ACTIVE")"
	case "$active_size" in ''|*[!0-9]*) active_size=0 ;; esac
	previous_size=0
	[ -f "$CORE_PREVIOUS" ] && previous_size="$(wc -c < "$CORE_PREVIOUS")"
	case "$previous_size" in ''|*[!0-9]*) previous_size=0 ;; esac
	candidate_size="$(wc -c < "$candidate" 2>/dev/null)"; case "$candidate_size" in ''|*[!0-9]*) return 1 ;; esac
	extra_slot_bytes=$((active_size - previous_size))
	[ "$extra_slot_bytes" -gt 0 ] || extra_slot_bytes=0
	required_kb=$(( (candidate_size + extra_slot_bytes + 1023) / 1024 + 1024 ))
	[ "$required_kb" -ge "$MIN_FREE_KB" ] || required_kb="$MIN_FREE_KB"
	check_minimum_space "$CORE_DIR" "$required_kb" || return 2

	was_running=0
	service_running && was_running=1
	new_path="$CORE_DIR/.mihomo.new.$$"
	active_backup="$CORE_DIR/.mihomo.update.active.$$"
	previous_backup="$CORE_DIR/.mihomo.update.previous.$$"
	previous_new="$CORE_DIR/.mihomo.update.new-previous.$$"
	restore_active="$CORE_DIR/.mihomo.update.restore-active.$$"
	restore_previous="$CORE_DIR/.mihomo.update.restore-previous.$$"
	cleanup_paths="$cleanup_paths $new_path $active_backup $previous_backup $previous_new $restore_active $restore_previous"

	stage_core_file "$candidate" "$new_path" || return 1
	[ "$(core_version "$new_path")" = "$candidate_version" ] || return 1

	active_existed=0
	previous_existed=0
	if [ -x "$CORE_ACTIVE" ]; then
		active_existed=1
		stage_core_file "$CORE_ACTIVE" "$active_backup" || return 1
	fi
	if [ -x "$CORE_PREVIOUS" ]; then
		previous_existed=1
		stage_core_file "$CORE_PREVIOUS" "$previous_backup" || return 1
	fi

	# Keep both original slots recoverable until the new core has restarted.
	# The candidate and previous-slot replacement are staged first, then moved
	# atomically within the same filesystem.
	if [ "$active_existed" -eq 1 ]; then
		stage_core_file "$active_backup" "$previous_new" || return 1
	fi
	if ! mv -f "$new_path" "$CORE_ACTIVE"; then
		return 1
	fi
	if [ "$active_existed" -eq 1 ]; then
		if ! mv -f "$previous_new" "$CORE_PREVIOUS"; then
			replace_core_slot "$active_backup" "$restore_active" "$CORE_ACTIVE" >/dev/null 2>&1 || :
			if [ "$previous_existed" -eq 1 ]; then
				replace_core_slot "$previous_backup" "$restore_previous" "$CORE_PREVIOUS" >/dev/null 2>&1 || :
			else
				rm -f "$CORE_PREVIOUS"
			fi
			return 1
		fi
	fi

	if [ "$was_running" -eq 1 ] && ! restart_service; then
		if [ "$active_existed" -eq 1 ]; then
			replace_core_slot "$active_backup" "$restore_active" "$CORE_ACTIVE" >/dev/null 2>&1 || :
		else
			rm -f "$CORE_ACTIVE"
		fi
		if [ "$previous_existed" -eq 1 ]; then
			replace_core_slot "$previous_backup" "$restore_previous" "$CORE_PREVIOUS" >/dev/null 2>&1 || :
		elif [ "$active_existed" -eq 1 ]; then
			rm -f "$CORE_PREVIOUS"
		fi
		restart_service >/dev/null 2>&1 || :
		return 1
	fi

	rm -f "$active_backup" "$previous_backup" "$previous_new" "$restore_active" "$restore_previous"
	return 0
}

update_core() {
	local archive candidate candidate_version installed_version previous_version active_existed rc tmp_required
	acquire_lock || return 1
	load_config
	ensure_active_core || { fail "无法准备内核目录"; return 1; }
	active_existed=0
	if [ -x "$CORE_ACTIVE" ]; then
		active_existed=1
		previous_version="$(cached_core_version current "$CORE_ACTIVE")"
	fi
	check_minimum_space "$TEMP_ROOT" "$MIN_FREE_KB" || { fail "空间不足，自行释放空间后重试"; return 1; }
	set_status updating ''
	archive="$TEMP_ROOT/nikki-core-download.$$"
	candidate="$TEMP_ROOT/nikki-core-candidate.$$"
	cleanup_paths="$cleanup_paths $archive $candidate"

	resolve_and_download "$archive" || { fail "无法从当前更新源找到适配本机架构的内核"; return 1; }
	tmp_required=$(( ($(wc -c < "$archive" 2>/dev/null) + 1023) / 1024 + MIN_FREE_KB ))
	check_minimum_space "$TEMP_ROOT" "$tmp_required" || { fail "空间不足，自行释放空间后重试"; return 1; }
	extract_candidate "$archive" "$candidate" || { fail "内核压缩包无法识别或解压失败"; return 1; }
	candidate_version="$(validate_candidate "$candidate")" || { fail "下载文件不是可运行的 Mihomo 内核"; return 1; }

	install_candidate "$candidate" "$candidate_version"
	rc=$?
	case "$rc" in
		0) ;;
		2) fail "空间不足，自行释放空间后重试"; return 1 ;;
		*) fail "新内核安装或服务重启失败，已保留原核心"; return 1 ;;
	esac
	installed_version="$candidate_version"
	cache_core_version current "$CORE_ACTIVE" "$installed_version"
	if [ "$active_existed" -eq 1 ] && [ -x "$CORE_PREVIOUS" ]; then
		[ -n "$previous_version" ] || previous_version="$(core_version "$CORE_PREVIOUS")"
		cache_core_version previous "$CORE_PREVIOUS" "$previous_version"
	fi
	state_set latest_version "$candidate_version"
	state_set installed_version "$installed_version"
	set_status success ''
	printf '%s\n' "$installed_version"
}

stage_core_file() {
	local source="$1" destination="$2"
	rm -f "$destination" || return 1
	# Both slots and staging files are on the same filesystem, so a hard link
	# normally provides a zero-copy snapshot. Fall back to copying when the
	# filesystem does not support hard links.
	ln "$source" "$destination" 2>/dev/null || cp "$source" "$destination" || return 1
	chmod 755 "$destination" || return 1
}

replace_core_slot() {
	local source="$1" staging="$2" destination="$3"
	stage_core_file "$source" "$staging" || return 1
	mv -f "$staging" "$destination" || return 1
}

rollback_core() {
	local was_running current_version previous_version active_backup previous_backup active_new previous_new restore_active restore_previous
	acquire_lock || return 1
	ensure_active_core || { fail "无法准备内核目录"; return 1; }
	[ -x "$CORE_ACTIVE" ] || { fail "当前核心不存在"; return 1; }
	[ -x "$CORE_PREVIOUS" ] || { fail "没有可回退的上一版本"; return 1; }
	current_version="$(cached_core_version current "$CORE_ACTIVE")"
	previous_version="$(cached_core_version previous "$CORE_PREVIOUS")"
	[ -n "$previous_version" ] || { fail "上一版本核心不可执行"; return 1; }

	was_running=0; service_running && was_running=1
	active_backup="$CORE_DIR/.mihomo.rollback.active.$$"
	previous_backup="$CORE_DIR/.mihomo.rollback.previous.$$"
	active_new="$CORE_DIR/.mihomo.rollback.new-active.$$"
	previous_new="$CORE_DIR/.mihomo.rollback.new-previous.$$"
	restore_active="$CORE_DIR/.mihomo.rollback.restore-active.$$"
	restore_previous="$CORE_DIR/.mihomo.rollback.restore-previous.$$"
	cleanup_paths="$cleanup_paths $active_backup $previous_backup $active_new $previous_new $restore_active $restore_previous"

	# Keep both original inodes reachable until the replacement has restarted
	# successfully. This avoids the transient empty-slot window of a three-mv
	# swap and makes rollback failure recovery deterministic.
	stage_core_file "$CORE_ACTIVE" "$active_backup" || { fail "无法备份当前核心"; return 1; }
	stage_core_file "$CORE_PREVIOUS" "$previous_backup" || { fail "无法备份上一版本"; return 1; }

	if ! replace_core_slot "$previous_backup" "$active_new" "$CORE_ACTIVE"; then
		fail "无法切换到上一版本"
		return 1
	fi
	if ! replace_core_slot "$active_backup" "$previous_new" "$CORE_PREVIOUS"; then
		replace_core_slot "$active_backup" "$restore_active" "$CORE_ACTIVE" >/dev/null 2>&1 || :
		replace_core_slot "$previous_backup" "$restore_previous" "$CORE_PREVIOUS" >/dev/null 2>&1 || :
		fail "无法完成两槽位交换"
		return 1
	fi

	if [ "$was_running" -eq 1 ] && ! restart_service; then
		replace_core_slot "$active_backup" "$restore_active" "$CORE_ACTIVE" >/dev/null 2>&1 || :
		replace_core_slot "$previous_backup" "$restore_previous" "$CORE_PREVIOUS" >/dev/null 2>&1 || :
		restart_service >/dev/null 2>&1 || :
		fail "回退版本启动失败，已恢复原核心"
		return 1
	fi

	rm -f "$active_backup" "$previous_backup" "$active_new" "$previous_new" "$restore_active" "$restore_previous"
	cache_core_version current "$CORE_ACTIVE" "$previous_version"
	cache_core_version previous "$CORE_PREVIOUS" "$current_version"
	set_status rolled_back ''
	printf '%s\n' "$previous_version"
}

delete_previous() {
	acquire_lock || return 1
	rm -f "$CORE_PREVIOUS" || { fail "删除上一版本失败"; return 1; }
	clear_core_version_cache previous
	set_status previous_deleted ''
}

print_status() {
	local package uname_arch active previous latest source status error updated resolved_url resolved_asset resolved_repository_base
	load_config
	ensure_active_core >/dev/null 2>&1 || :
	package="$(package_architecture)"
	uname_arch="$("$UNAME_BIN" -m 2>/dev/null)"
	active="$(cached_core_version current "$CORE_ACTIVE")"
	previous="$(cached_core_version previous "$CORE_PREVIOUS")"
	latest="$(state_get latest_version)"
	source="$(state_get source)"; [ -n "$source" ] || source="$(source_label)"
	status="$(state_get last_status)"; [ -n "$status" ] || status=idle
	error="$(state_get last_error)"
	updated="$(state_get last_update)"
	resolved_url="$(state_get resolved_url)"
	resolved_asset="$(state_get resolved_asset)"
	resolved_repository_base="$(state_get resolved_repository_base)"
	printf 'architecture_uname\t%s\n' "$(single_line "$uname_arch")"
	printf 'architecture_package\t%s\n' "$(single_line "$package")"
	printf 'current_version\t%s\n' "$(single_line "$active")"
	printf 'previous_version\t%s\n' "$(single_line "$previous")"
	printf 'latest_version\t%s\n' "$(single_line "$latest")"
	printf 'source\t%s\n' "$(single_line "$source")"
	printf 'status\t%s\n' "$(single_line "$status")"
	printf 'error\t%s\n' "$(single_line "$error")"
	printf 'updated_at\t%s\n' "$(single_line "$updated")"
	printf 'resolved_url\t%s\n' "$(single_line "$resolved_url")"
	printf 'resolved_asset\t%s\n' "$(single_line "$resolved_asset")"
	printf 'resolved_repository_base\t%s\n' "$(single_line "$resolved_repository_base")"
	printf 'active_path\t%s\n' "$CORE_ACTIVE"
	printf 'previous_path\t%s\n' "$CORE_PREVIOUS"
}

case "${1:-status}" in
	status) print_status ;;
	check) acquire_lock && { check_source >/dev/null || fail "无法检查当前更新源"; } ;;
	update) update_core ;;
	rollback) rollback_core ;;
	delete-previous) delete_previous ;;
	migrate) ensure_active_core ;;
	architectures) architecture_candidates ;;
	*) printf 'Usage: %s {status|check|update|rollback|delete-previous|migrate|architectures}\n' "$0" >&2; exit 2 ;;
esac
