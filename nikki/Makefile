include $(TOPDIR)/rules.mk

PKG_NAME:=nikki
PKG_VERSION:=2026.07.17.legacy5.3
PKG_RELEASE:=1
PKGARCH:=all

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Nikki Legacy contributors

include $(INCLUDE_DIR)/package.mk

define Package/nikki
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Nikki legacy transparent proxy for firewall3/xtables
  URL:=https://github.com/nikkinikki-org/OpenWrt-nikki
  DEPENDS:=+ca-bundle +curl +yq +jshn +jsonfilter +ubus +firewall +iptables +ip6tables +ipset +ip-full \
    +iptables-mod-tproxy +iptables-mod-extra +iptables-mod-ipopt \
    +kmod-ipt-ipset +kmod-tun
endef

define Package/nikki/description
  A firewall3/xtables-oriented Nikki fork for OpenWrt 21.02-class systems.
  The backend supports per-family TCP/UDP REDIRECT, TPROXY and TUN routing,
  IPv4 DNS REDIRECT to Mihomo DNS, and IPv6 DNS TPROXY without ucode.
endef

define Package/nikki/conffiles
/etc/config/nikki
/etc/nikki/mixin.yaml
endef

define Package/nikki/install
	$(INSTALL_DIR) $(1)/etc/nikki
	$(INSTALL_DIR) $(1)/etc/nikki/scripts
	$(INSTALL_DIR) $(1)/etc/nikki/ipset
	$(INSTALL_DIR) $(1)/etc/nikki/profiles
	$(INSTALL_DIR) $(1)/etc/nikki/subscriptions
	$(INSTALL_DIR) $(1)/etc/nikki/run
	$(INSTALL_DIR) $(1)/etc/nikki/run/providers
	$(INSTALL_DIR) $(1)/etc/nikki/run/providers/rule
	$(INSTALL_DIR) $(1)/etc/nikki/run/providers/proxy
	$(INSTALL_DIR) $(1)/usr/libexec/nikki

	$(INSTALL_DATA) $(CURDIR)/files/mixin.yaml $(1)/etc/nikki/mixin.yaml
	$(INSTALL_DATA) $(CURDIR)/files/ipset/geoip_cn.txt $(1)/etc/nikki/ipset/geoip_cn.txt
	$(INSTALL_DATA) $(CURDIR)/files/ipset/geoip6_cn.txt $(1)/etc/nikki/ipset/geoip6_cn.txt

	$(INSTALL_BIN) $(CURDIR)/files/scripts/include.sh $(1)/etc/nikki/scripts/include.sh
	$(INSTALL_BIN) $(CURDIR)/files/scripts/mixin.sh $(1)/etc/nikki/scripts/mixin.sh
	$(INSTALL_BIN) $(CURDIR)/files/scripts/firewall_fw3.sh $(1)/etc/nikki/scripts/firewall_fw3.sh
	$(INSTALL_BIN) $(CURDIR)/files/scripts/firewall_include.sh $(1)/etc/nikki/scripts/firewall_include.sh
	$(INSTALL_BIN) $(CURDIR)/files/scripts/debug.sh $(1)/etc/nikki/scripts/debug.sh
	$(INSTALL_BIN) $(CURDIR)/files/scripts/core_update.sh $(1)/etc/nikki/scripts/core_update.sh

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/nikki.conf $(1)/etc/config/nikki

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/nikki.init $(1)/etc/init.d/nikki

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/uci-defaults/firewall.sh $(1)/etc/uci-defaults/99_firewall_nikki
	$(INSTALL_BIN) $(CURDIR)/files/uci-defaults/init.sh $(1)/etc/uci-defaults/99_init_nikki
	$(INSTALL_BIN) $(CURDIR)/files/uci-defaults/migrate.sh $(1)/etc/uci-defaults/99_migrate_nikki

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) $(CURDIR)/files/nikki.upgrade $(1)/lib/upgrade/keep.d/nikki
endef

define Package/nikki/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	[ -x /etc/init.d/nikki ] && /etc/init.d/nikki stop >/dev/null 2>&1
	[ -x /etc/nikki/scripts/firewall_fw3.sh ] && /etc/nikki/scripts/firewall_fw3.sh remove >/dev/null 2>&1
fi
endef

define Package/nikki/postrm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	uci -q batch <<-EOF_UCI >/dev/null
		delete firewall.nikki
		commit firewall
	EOF_UCI
fi
endef

define Build/Compile
endef

$(eval $(call BuildPackage,nikki))
