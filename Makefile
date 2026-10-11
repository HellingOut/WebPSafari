ARCHS = armv7 arm64
TARGET = iphone:clang:8.4:8.0
INSTALL_TARGET_PROCESSES = MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WebPSafari

WebPSafari_FILES = Tweak.m
WebPSafari_CFLAGS = -fobjc-arc -fno-modules -DTHEOS_LEAN_AND_MEAN \
	-I$(THEOS_PROJECT_DIR)/libwebp/include
WebPSafari_LDFLAGS = -L$(THEOS_PROJECT_DIR)/libwebp/lib -lwebp
WebPSafari_FRAMEWORKS = Foundation CoreGraphics ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk
