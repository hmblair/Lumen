# Lumen — build and packaging.
# Author: Hamish M. Blair <hmblair@stanford.edu>

# Personal values live in an untracked Makefile.local:
#   TEAM_ID := <Apple team ID>    # enables iOS code signing
#   DEVICE  := <device name>      # for ios-install / ios-run
-include Makefile.local

APP_NAME  := Lumen
BUILD_DIR := .build
APP_DIR   := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR := $(APP_DIR)/Contents/MacOS
PLIST     := $(APP_DIR)/Contents/Info.plist
DIST_DIR  := $(BUILD_DIR)/dist
STAGE_DIR := $(DIST_DIR)/root

# A copy that leaves this machine has to run on Intel too. Each architecture
# is built on its own and the results joined with `lipo`, rather than SwiftPM's
# `--arch a --arch b`, which needs the full Xcode toolchain (xcbuild); this way
# the Command Line Tools are enough.
ARCHS         := arm64 x86_64
UNIVERSAL_BIN := $(BUILD_DIR)/universal/$(APP_NAME)

# SwiftPM owns its output layout, so every binary path is asked for rather than
# spelled out. BIN is what lands in the bundle: the native build normally, the
# universal one for `dist` (set per-target below).
bin_for = $(shell swift build -c release --arch $(1) --show-bin-path)/$(APP_NAME)
BIN     = $(shell swift build -c release --show-bin-path)/$(APP_NAME)

# The marketing version's one home is Resources/Info.plist — macOS's canonical
# place for it — and it is read back from there rather than repeated. The build
# number is the commit count: monotonic, and it maps any copy in the wild to a
# commit, as does the revision stamped beside it.
VERSION      = $(shell plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
BUILD_NUMBER = $(shell git rev-list --count HEAD)
REVISION     = $(shell git rev-parse --short HEAD)
DMG          = $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg

# Ad-hoc is all a locally built copy needs, and is the default. Shipping to
# someone else's Mac needs both of these: a Developer ID signature that
# Gatekeeper trusts, and notarization to clear the quarantine flag a download
# arrives with. Create the notary profile once with
# `xcrun notarytool store-credentials`.
#
#   make dist SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#             NOTARY_PROFILE=lumen
SIGN_IDENTITY  ?= -
NOTARY_PROFILE ?=

# Notarization requires the hardened runtime; an ad-hoc signature has no use
# for it.
CODESIGN_FLAGS = $(if $(filter-out -,$(SIGN_IDENTITY)),--options runtime,)

.PHONY: all build release universal run app bundle dist install clean daemon-logs \
	ios ios-project ios-install ios-run require-ios-device

# `dist` stages the binary its prerequisites produce, so the two must not
# overlap; swift build parallelizes internally either way.
.NOTPARALLEL:

all: build

build:
	swift build

release:
	swift build -c release

# One binary carrying both architectures, for distribution.
universal:
	for arch in $(ARCHS); do swift build -c release --arch $$arch || exit 1; done
	@mkdir -p "$(dir $(UNIVERSAL_BIN))"
	lipo -create -output "$(UNIVERSAL_BIN)" \
		$(foreach arch,$(ARCHS),"$(call bin_for,$(arch))")

run:
	swift run

# Wrap the release binary in a .app bundle so it runs as a background menu-bar
# agent (LSUIElement in Resources/Info.plist), independent of any terminal.
# `bundle` is an alias for `app`.
app bundle: release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(MACOS_DIR)"
	cp "$(BIN)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(PLIST)"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(PLIST)"
	plutil -replace LumenGitRevision -string "$(REVISION)" "$(PLIST)"
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$(APP_DIR)"
	@echo "Built $(APP_DIR) — $(VERSION) ($(BUILD_NUMBER), $(REVISION))"
	@echo "Install with: make install    Run with: open \"$(APP_DIR)\""

# A universal, signed disk image to hand to someone else, notarized and
# stapled when a notary profile is configured — without that, the recipient
# has to clear the quarantine flag by hand, so say so rather than let them
# meet "Lumen is damaged" instead.
dist: BIN = $(UNIVERSAL_BIN)
dist: universal app
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(STAGE_DIR)"
	cp -R "$(APP_DIR)" "$(STAGE_DIR)/"
	ln -s /Applications "$(STAGE_DIR)/Applications"
	hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(STAGE_DIR)" \
		-ov -format UDZO "$(DMG)"
	rm -rf "$(STAGE_DIR)"
	@if [ -n "$(NOTARY_PROFILE)" ]; then \
		xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait \
			&& xcrun stapler staple "$(DMG)"; \
	else \
		echo; \
		echo "Built $(DMG) — $(VERSION) ($(BUILD_NUMBER), $(REVISION)), signed \"$(SIGN_IDENTITY)\"."; \
		echo "Not notarized: on another Mac this opens only after"; \
		echo "  xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"; \
		echo "Set SIGN_IDENTITY and NOTARY_PROFILE to ship one that just opens."; \
	fi

# Replace rather than copy over: cp -R onto an existing bundle merges the two,
# leaving stale files behind from whatever was installed before.
install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" /Applications/
	@echo "Installed /Applications/$(APP_NAME).app"

# --- iOS ---------------------------------------------------------------------
# The iOS app is the shared package behind a thin shell in Apps/iOS. The Xcode
# project is generated from Apps/project.yml, the one description of the app.

IOS_PROJECT   := Apps/$(APP_NAME).xcodeproj
IOS_SCHEME    := LumeniOS
IOS_BUILD_DIR := $(BUILD_DIR)/ios
IOS_APP       := $(IOS_BUILD_DIR)/Build/Products/Release-iphoneos/$(APP_NAME).app
IOS_BUNDLE_ID := com.hmblair.lumen

# Signing is optional, so a clone with no Apple account still builds.
ifeq ($(TEAM_ID),)
IOS_SIGNING := CODE_SIGNING_ALLOWED=NO
else
IOS_SIGNING := -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM_ID)
endif

ios-project:
	cd Apps && xcodegen generate

ios: ios-project
	xcodebuild -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) \
		-configuration Release -destination 'generic/platform=iOS' \
		-derivedDataPath $(IOS_BUILD_DIR) \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		$(IOS_SIGNING) -quiet build

ios-install: require-ios-device ios
	xcrun devicectl device install app --device "$(DEVICE)" "$(IOS_APP)"
	@echo "Installed on $(DEVICE)"

ios-run: ios-install
	xcrun devicectl device process launch --device "$(DEVICE)" $(IOS_BUNDLE_ID)

require-ios-device:
	@test -n "$(DEVICE)" || { echo "Set DEVICE in Makefile.local or on the command line."; exit 1; }

clean:
	swift package clean
	rm -rf "$(APP_DIR)" "$(DIST_DIR)" "$(dir $(UNIVERSAL_BIN))"
	rm -rf "$(IOS_PROJECT)" Apps/iOS/Info.plist

# The Linux half lives in daemon/ and is built on the box; see daemon/README.md.
# Point DAEMON_HOST at whatever `ssh` accepts for that machine.
daemon-logs:
	@test -n "$(DAEMON_HOST)" || { echo "Set DAEMON_HOST, e.g. make daemon-logs DAEMON_HOST=user@host"; exit 1; }
	ssh $(DAEMON_HOST) 'XDG_RUNTIME_DIR=/run/user/$$(id -u) \
		journalctl --user -u lumen-daemon -n 50 --no-pager'
