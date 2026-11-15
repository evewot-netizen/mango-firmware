include $(TOPDIR)/rules.mk

PKG_NAME:=mango-management
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/mango-management
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Mango management enrollment and gateway guard
  DEPENDS:=+wireguard-tools +kmod-wireguard +firewall +lua +luaposix +lua-jsonc +coreutils-timeout
endef

define Package/mango-management/conffiles
/etc/config/mango_management
endef

define Build/Compile
endef

define Package/mango-management/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/. $(1)/
endef

$(eval $(call BuildPackage,mango-management))
