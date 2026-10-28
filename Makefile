# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
# Clean-room reimplementation of Apple's CoreAnalytics private framework.
#
#   make                 # build CoreAnalytics.framework for CONFIG (default release)
#   make CONFIG=debug    # debug build
#   make test            # JSON checks, export parity, payload parity with Apple's
#   make clean
#
# The framework keeps Apple's install name, so a binary linked against it
# loads Apple's copy by default; DYLD_FRAMEWORK_PATH=build/<CONFIG> swaps in
# this one (and the other way round).
#
# Everything lands under build/.  The Makefile is portable to both GNU make and
# BSD make (bmake): no pattern rules, no ifeq/ifdef/.if conditionals and no
# $(if)/$(shell) functions.  Per-config flags come from make/<CONFIG>.mk.

CONFIG ?= release
SDK    ?= /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
CC     := /Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang
SWIFTC := /Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc

-include make/$(CONFIG).mk

BUILD_DIR := build/$(CONFIG)
OBJDIR    := $(BUILD_DIR)/obj

FW_SRC := src/CoreAnalytics
MFLAGS := $(OPT) -fobjc-arc -fblocks -isysroot "$(SDK)" -Wall -Wextra -Iinclude -I$(FW_SRC)

FRAMEWORK := $(BUILD_DIR)/CoreAnalytics.framework
FW_VER    := $(FRAMEWORK)/Versions/A
INSTALL_NAME := /System/Library/PrivateFrameworks/CoreAnalytics.framework/Versions/A/CoreAnalytics

HDRS := include/CoreAnalytics/CoreAnalytics.h $(FW_SRC)/ca_internal.h
OBJS := $(OBJDIR)/api.o $(OBJDIR)/client.o $(OBJDIR)/json.o $(OBJDIR)/observers.o \
	$(OBJDIR)/QueryValues.o $(OBJDIR)/cpp_stubs.o

all: $(FRAMEWORK)/CoreAnalytics

$(FRAMEWORK)/CoreAnalytics: $(OBJS) $(FW_SRC)/CoreAnalytics.exp $(FW_SRC)/Info.plist
	@mkdir -p $(FW_VER)/Headers $(FW_VER)/Resources
	$(CC) $(MFLAGS) -dynamiclib -install_name $(INSTALL_NAME) \
	    -compatibility_version 1 -current_version 1 \
	    -exported_symbols_list $(FW_SRC)/CoreAnalytics.exp \
	    -o $(FW_VER)/CoreAnalytics $(OBJS) -framework Foundation -framework CoreFoundation -lc++ \
	    -L"$(SDK)/usr/lib/swift"
	cp include/CoreAnalytics/CoreAnalytics.h $(FW_VER)/Headers/CoreAnalytics.h
	cp $(FW_SRC)/Info.plist $(FW_VER)/Resources/Info.plist
	ln -sfh A $(FRAMEWORK)/Versions/Current
	ln -sfh Versions/Current/CoreAnalytics $(FRAMEWORK)/CoreAnalytics
	ln -sfh Versions/Current/Headers $(FRAMEWORK)/Headers
	ln -sfh Versions/Current/Resources $(FRAMEWORK)/Resources

$(OBJDIR)/api.o: $(FW_SRC)/api.m $(HDRS)
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -c -o $@ $(FW_SRC)/api.m

$(OBJDIR)/client.o: $(FW_SRC)/client.m $(HDRS)
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -c -o $@ $(FW_SRC)/client.m

$(OBJDIR)/json.o: $(FW_SRC)/json.m $(HDRS)
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -c -o $@ $(FW_SRC)/json.m

# Objective-C++ so a rejected subscription throws std::runtime_error.
$(OBJDIR)/observers.o: $(FW_SRC)/observers.mm $(HDRS)
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -std=c++17 -c -o $@ $(FW_SRC)/observers.mm

# The Swift export.  Its module is named CoreAnalytics (the symbol's
# mangling depends on it) and imports the framework's C header as its
# underlying Clang module; the Swift runtime libraries are autolinked.
$(OBJDIR)/QueryValues.o: $(FW_SRC)/QueryValues.swift $(FW_SRC)/CoreAnalytics.modulemap \
	include/CoreAnalytics/CoreAnalytics.h
	@mkdir -p $(OBJDIR)
	$(SWIFTC) -sdk "$(SDK)" $(SWIFTOPT) -parse-as-library -module-name CoreAnalytics \
	    -import-underlying-module -Xcc -fmodule-map-file=$(FW_SRC)/CoreAnalytics.modulemap \
	    -Xcc -Iinclude -c -o $@ $(FW_SRC)/QueryValues.swift

# The JSON writer is internal, so its check links json.o directly.
JSON_CHECK := $(BUILD_DIR)/json_check

$(JSON_CHECK): tests/json_check.m $(OBJDIR)/json.o $(HDRS)
	$(CC) $(MFLAGS) -o $@ tests/json_check.m $(OBJDIR)/json.o -framework Foundation

json-check: $(JSON_CHECK)
	$(JSON_CHECK)

# Event JSON must match Apple's byte for byte; see tests/payload-parity.sh.
PAYLOAD_GEN := $(BUILD_DIR)/payload_gen
CAPTURE_LIB := $(BUILD_DIR)/capture_send.dylib

$(PAYLOAD_GEN): tests/payload_gen.m include/CoreAnalytics/CoreAnalytics.h $(FRAMEWORK)/CoreAnalytics
	$(CC) $(MFLAGS) -F$(BUILD_DIR) -o $@ tests/payload_gen.m -framework CoreAnalytics -framework Foundation

$(CAPTURE_LIB): tests/capture_send.c
	$(CC) $(OPT) -fblocks -isysroot "$(SDK)" -dynamiclib -o $@ tests/capture_send.c

payload-parity: $(PAYLOAD_GEN) $(CAPTURE_LIB)
	GEN="$(PAYLOAD_GEN)" CAP="$(CAPTURE_LIB)" FWDIR="$(BUILD_DIR)" bash tests/payload-parity.sh

# Every exported symbol of our framework must be one of Apple's C exports.
exports-check: all
	FW="build/$(CONFIG)/CoreAnalytics.framework/CoreAnalytics" bash tests/exports.sh

test: json-check exports-check payload-parity

$(OBJDIR)/cpp_stubs.o: $(FW_SRC)/cpp_stubs.mm
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -std=c++17 -c -o $@ $(FW_SRC)/cpp_stubs.mm

clean:
	rm -rf build

.PHONY: all json-check exports-check payload-parity test clean
