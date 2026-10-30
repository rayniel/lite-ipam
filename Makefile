include $(TOPDIR)/rules.mk

PKG_NAME:=lite-ipam
PKG_RELEASE:=9
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=GitHub Copilot
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/lite-ipam
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Services
  TITLE:=Lightweight IPAM foundation for OpenWrt
	DEPENDS:=+sqlite3-cli +mailsend +flock
endef

define Package/lite-ipam/description
 A lightweight IPAM foundation package for OpenWrt providing
 UCI-backed runtime path management and SQLite schema initialization.
endef

define Package/luci-app-lite-ipam
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI read-only API for lite-ipam
	DEPENDS:=+lite-ipam +luci-base +luci-lua-runtime
endef

define Package/luci-app-lite-ipam/description
 Read-only LuCI API endpoints for lite-ipam runtime and SQLite data.
endef

define Build/Compile
endef

define Package/lite-ipam/conffiles
/etc/config/lite-ipam
endef

define Package/lite-ipam/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/lite-ipam.config $(1)/etc/config/lite-ipam
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/lite-ipam.init $(1)/etc/init.d/lite-ipam
	$(INSTALL_DIR) $(1)/etc/hotplug.d/dhcp
	$(INSTALL_BIN) ./files/90-lite-ipam $(1)/etc/hotplug.d/dhcp/90-lite-ipam
	$(INSTALL_DIR) $(1)/usr/libexec/lite-ipam
	$(INSTALL_BIN) ./files/lite-ipam.sh $(1)/usr/libexec/lite-ipam/lite-ipam.sh
	$(INSTALL_BIN) ./files/dnsmasq-lease-hook.sh $(1)/usr/libexec/lite-ipam/dnsmasq-lease-hook.sh
	$(INSTALL_BIN) ./files/daily-backup-and-mail.sh $(1)/usr/libexec/lite-ipam/daily-backup-and-mail.sh
	$(INSTALL_DATA) ./files/schema-v1.sql $(1)/usr/libexec/lite-ipam/schema-v1.sql
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/lite-ipamctl $(1)/usr/sbin/lite-ipamctl
endef

define Package/luci-app-lite-ipam/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/luci/controller/lite_ipam.lua $(1)/usr/lib/lua/luci/controller/lite_ipam.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model
	$(INSTALL_DATA) ./files/luci/model/lite_ipam.lua $(1)/usr/lib/lua/luci/model/lite_ipam.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/lite_ipam
	$(INSTALL_DATA) ./files/luci/view/lite_ipam/style.htm $(1)/usr/lib/lua/luci/view/lite_ipam/style.htm
	$(INSTALL_DATA) ./files/luci/view/lite_ipam/ui.htm $(1)/usr/lib/lua/luci/view/lite_ipam/ui.htm
	$(INSTALL_DATA) ./files/luci/view/lite_ipam/overview.htm $(1)/usr/lib/lua/luci/view/lite_ipam/overview.htm
	$(INSTALL_DATA) ./files/luci/view/lite_ipam/settings.htm $(1)/usr/lib/lua/luci/view/lite_ipam/settings.htm
	$(INSTALL_DATA) ./files/luci/view/lite_ipam/subnets.htm $(1)/usr/lib/lua/luci/view/lite_ipam/subnets.htm
	$(INSTALL_DATA) ./files/luci/view/lite_ipam/logs.htm $(1)/usr/lib/lua/luci/view/lite_ipam/logs.htm
	$(INSTALL_DATA) ./files/luci/view/lite_ipam/manage.htm $(1)/usr/lib/lua/luci/view/lite_ipam/manage.htm
endef

$(eval $(call BuildPackage,lite-ipam))
$(eval $(call BuildPackage,luci-app-lite-ipam))