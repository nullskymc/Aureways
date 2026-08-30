DERIVED ?= .derived
SCHEME ?= Aureways

# Command Line Tools does not ship xcodebuild. Prefer a full Xcode.app if
# xcode-select still points at /Library/Developer/CommandLineTools.
ifeq ($(origin DEVELOPER_DIR), undefined)
XCODE_SELECT := $(shell xcode-select -p 2>/dev/null)
ifneq ($(findstring CommandLineTools,$(XCODE_SELECT)),)
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
else ifneq ($(wildcard /Applications/Xcode-beta.app/Contents/Developer),)
DEVELOPER_DIR := /Applications/Xcode-beta.app/Contents/Developer
endif
endif
endif
ifneq ($(DEVELOPER_DIR),)
export DEVELOPER_DIR
endif

.PHONY: build test open clean

build:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build

test:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) test

open: build
	open $(DERIVED)/Build/Products/Debug/Aureways.app

clean:
	rm -rf $(DERIVED)
