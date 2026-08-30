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

.PHONY: build release test open clean

# SwiftTerm ships a build tool plugin; skip interactive plugin validation so
# command-line builds do not stall on approval.
XCBUILD_FLAGS := -skipPackagePluginValidation

build:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) build

release:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) build

test:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) test

open: build
	open $(DERIVED)/Build/Products/Debug/Aureways.app

clean:
	rm -rf $(DERIVED)
