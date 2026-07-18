include $(TOPDIR)/rules.mk

PKG_VERSION:=1.26.1-v6
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for nikki
LUCI_DEPENDS:=+luci-base +nikki

# luci.mk copies files from root/ with their source permissions. GitHub web
# uploads and Windows ZIP extraction may lose the executable bit, so enforce
# the helper mode in the package build directory before the IPK is created.
define Prepare/SetNikkiRpcExecutable
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/nikki-rpc
endef
Hooks/Prepare/Post += Prepare/SetNikkiRpcExecutable

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
