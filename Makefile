# Feature —— 从 SystemX 拆出的桌面功能（theos 工程，可在设备上直接 make package）
TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBXDesktop
SBXDesktop_FILES = src/SBXDesktop.mm
SBXDesktop_CFLAGS = -fobjc-arc
SBXDesktop_FRAMEWORKS = Foundation UIKit Metal MetalKit QuartzCore CoreGraphics
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = SBXDesktopPrefs
SBXDesktopPrefs_FILES = prefs/SBXDesktopPrefs.mm
SBXDesktopPrefs_CFLAGS = -fobjc-arc
SBXDesktopPrefs_FRAMEWORKS = Foundation UIKit
SBXDesktopPrefs_INSTALL_PATH = /Library/PreferenceBundles
include $(THEOS_MAKE_PATH)/bundle.mk
