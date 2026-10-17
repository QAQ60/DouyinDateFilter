TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = DouyinDateFilter
DouyinDateFilter_FILES = Tweak.mm rg_date_filter.c
DouyinDateFilter_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/library.mk
