THEOS ?= $(HOME)/theos
ARCHS ?= arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = WeChat
THEOS_PACKAGE_SCHEME ?= rootless
FINALPACKAGE = 1
DEBUG = 0
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = WeChatFnAlbum
WeChatFnAlbum_FILES = Tweak.xm Sources/FNProtocol.m Sources/FNHost.m Sources/FNBrowser.m Sources/FNCategories.m Sources/FNWeChatBridge.m Sources/FNImageDelivery.m Sources/FNMediaHandoff.m Sources/FNTimelineScrubber.m Sources/FNPreviewLoadingView.m Sources/FNPreviewAudio.m Sources/FNZoomImageView.m Sources/FNNetworkRouting.m
WeChatFnAlbum_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-mismatched-parameter-types
ifeq ($(FN_DEVICE_TESTS),1)
WeChatFnAlbum_CFLAGS += -DFN_DEVICE_TESTS=1
endif
ifeq ($(FN_UI_DIAGNOSTICS),1)
WeChatFnAlbum_CFLAGS += -DFN_UI_DIAGNOSTICS=1
endif
ifeq ($(FN_VIDEO_PROBE),1)
WeChatFnAlbum_CFLAGS += -DFN_VIDEO_PROBE=1
endif
WeChatFnAlbum_LDFLAGS = -Wl,-install_name,@rpath/WeChatFnAlbum.dylib
WeChatFnAlbum_FRAMEWORKS = UIKit Foundation Security ImageIO AVFoundation AVKit Photos WebKit CoreLocation NetworkExtension
WeChatFnAlbum_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
include $(THEOS_MAKE_PATH)/tweak.mk
after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/WeChatFnAlbum.bundle
	cp -R Resources/WeChatFnAlbum.bundle/. $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/WeChatFnAlbum.bundle/
