# Builds hev-socks5-tunnel (MIT, https://github.com/heiher/hev-socks5-tunnel,
# tag 2.17.1, commit 9a06bc6e7989da54e3d32ff701ef7a7ce4995d3a, with its
# submodules vendored in ./hev-socks5-tunnel) as libhev-socks5-tunnel.so.
#
# This follows the library target of hev's own Android.mk (without the
# standalone executable) and the original FoxyVPN Android app's setup
# (https://github.com/vauth/FoxyVPN, MIT): the JNI entry points are registered
# for the class com.foxyvpn.app.vpn.HevSocks5Tunnel (see PKGNAME / CLSNAME).

HEV_TOP := $(call my-dir)/hev-socks5-tunnel

ifeq ($(filter $(modules-get-list),yaml),)
    include $(HEV_TOP)/third-part/yaml/Android.mk
endif
ifeq ($(filter $(modules-get-list),lwip),)
    include $(HEV_TOP)/third-part/lwip/Android.mk
endif
ifeq ($(filter $(modules-get-list),hev-task-system),)
    include $(HEV_TOP)/third-part/hev-task-system/Android.mk
endif

LOCAL_PATH := $(HEV_TOP)
SRCDIR := $(LOCAL_PATH)/src
# No git checkout here: pin the version string instead of asking git.
REV_ID := 2.17.1
include $(LOCAL_PATH)/build.mk

HEV_SOCKS5_TUNNEL_SRC := $(patsubst $(SRCDIR)/%,src/%,$(SRCFILES))
HEV_SOCKS5_TUNNEL_INCLUDES := \
    $(LOCAL_PATH)/src \
    $(LOCAL_PATH)/src/misc \
    $(LOCAL_PATH)/src/core/include \
    $(LOCAL_PATH)/third-part/yaml/include \
    $(LOCAL_PATH)/third-part/lwip/src/include \
    $(LOCAL_PATH)/third-part/lwip/src/ports/include \
    $(LOCAL_PATH)/third-part/hev-task-system/include

include $(CLEAR_VARS)
LOCAL_MODULE := hev-socks5-tunnel
LOCAL_SRC_FILES := $(HEV_SOCKS5_TUNNEL_SRC)
LOCAL_C_INCLUDES := $(HEV_SOCKS5_TUNNEL_INCLUDES)
LOCAL_CFLAGS += -DFD_SET_DEFINED -DSOCKLEN_T_DEFINED -DENABLE_LIBRARY
LOCAL_CFLAGS += -DPKGNAME=com/foxyvpn/app/vpn -DCLSNAME=HevSocks5Tunnel
LOCAL_CFLAGS += $(VERSION_CFLAGS)
ifeq ($(TARGET_ARCH_ABI),armeabi-v7a)
LOCAL_CFLAGS += -mfpu=neon
endif
LOCAL_STATIC_LIBRARIES := yaml lwip hev-task-system
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
include $(BUILD_SHARED_LIBRARY)
