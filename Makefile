ifeq ($(SIMULATOR),1)
	TARGET = simulator:clang:latest:15.0
else
	TARGET = iphone:clang:latest:15.0
endif
INSTALL_TARGET_PROCESSES = YouTube
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YouVOT

$(TWEAK_NAME)_FILES = Tweak.x $(wildcard Sources/*.m)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = UIKit AVFoundation CoreMedia QuartzCore NaturalLanguage WebKit Security

include $(THEOS_MAKE_PATH)/tweak.mk
