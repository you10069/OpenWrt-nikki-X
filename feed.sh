#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
buildroot=${1:-}

if [ -z "$buildroot" ] || [ ! -f "$buildroot/rules.mk" ] || [ ! -d "$buildroot/package" ]; then
	echo "Usage: $0 /path/to/openwrt-buildroot" >&2
	exit 2
fi

buildroot=$(CDPATH= cd -- "$buildroot" && pwd)
link_path="$buildroot/package/feeds/nikki-legacy"
mkdir -p "$link_path"

# Link package directories individually. Linking the repository root itself as
# one package confuses the OpenWrt package scanner because the root has no
# package Makefile.
for package in nikki luci-app-nikki mihomo-meta mihomo-alpha; do
	rm -rf "$link_path/$package"
	ln -s "$repo_dir/$package" "$link_path/$package"
done

cat <<EOF_DONE
Linked Nikki Legacy packages into:
  $link_path

Next steps:
  cd $buildroot
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  make menuconfig
EOF_DONE
