# HueBar — build and packaging.
# Author: Hamish M. Blair <hmblair@stanford.edu>

APP_NAME  := HueBar
APP_DIR   := .build/$(APP_NAME).app
MACOS_DIR := $(APP_DIR)/Contents/MacOS

.PHONY: all build release run app bundle install clean

all: build

build:
	swift build

release:
	swift build -c release

run:
	swift run

# Wrap the release binary in a .app bundle so it runs as a background menu-bar
# agent (LSUIElement in Resources/Info.plist), independent of any terminal.
# `bundle` is an alias for `app`.
app bundle: release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(MACOS_DIR)"
	cp ".build/release/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	codesign --force --sign - "$(APP_DIR)"
	@echo "Built $(APP_DIR)"
	@echo "Install with: make install    Run with: open \"$(APP_DIR)\""

install: app
	cp -R "$(APP_DIR)" /Applications/
	@echo "Installed /Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf "$(APP_DIR)"
