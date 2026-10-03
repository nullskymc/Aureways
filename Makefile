DERIVED ?= .derived
SCHEME ?= Aureways

# Command Line Tools does not ship xcodebuild. Prefer a full Xcode.app if
# xcode-select still points at /Library/Developer/CommandLineTools.
# This machine keeps Xcode on the app volume, not in /Applications.
ifeq ($(origin DEVELOPER_DIR), undefined)
XCODE_SELECT := $(shell xcode-select -p 2>/dev/null)
ifneq ($(findstring CommandLineTools,$(XCODE_SELECT)),)
XCODE_CANDIDATES := \
	/Applications/Xcode.app \
	/Applications/Xcode-beta.app \
	/Volumes/app/Applications/Xcode.app \
	/Volumes/app/Applications/Xcode-beta.app
XCODE_APP := $(firstword $(wildcard $(XCODE_CANDIDATES)))
ifeq ($(XCODE_APP),)
XCODE_APP := $(firstword $(shell mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null))
endif
ifneq ($(XCODE_APP),)
DEVELOPER_DIR := $(XCODE_APP)/Contents/Developer
endif
endif
endif
ifneq ($(DEVELOPER_DIR),)
export DEVELOPER_DIR
endif

.PHONY: build release test open clean web

# SwiftTerm ships a build tool plugin; skip interactive plugin validation so
# command-line builds do not stall on approval (macro validation likewise, in
# case a dependency adds a macro package).
DESTINATION ?= platform=macOS
XCBUILD_FLAGS := -skipPackagePluginValidation -skipMacroValidation -destination '$(DESTINATION)'
ifneq ($(QUIET),)
XCBUILD_FLAGS += -quiet
endif
APP := $(DERIVED)/Build/Products/Debug/Aureways.app
INSTALL_APP := /Applications/Aureways.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

build:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) build

release:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) build

test:
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) test

# Launch Services keys the Dock icon by bundle id. A stale copy in
# /Applications (this one had no icon) wins over the just-built Debug app,
# so `open` looks like it still has the empty placeholder. Replace that
# copy when it exists, then open the Applications one.
open: build
	@if [ -d "$(INSTALL_APP)" ]; then \
		echo "Updating $(INSTALL_APP) so Dock uses this build's icon"; \
		killall Aureways >/dev/null 2>&1 || true; \
		rm -rf "$(INSTALL_APP)"; \
		ditto "$(APP)" "$(INSTALL_APP)"; \
		$(LSREGISTER) -f "$(INSTALL_APP)"; \
		open "$(INSTALL_APP)"; \
	else \
		$(LSREGISTER) -f "$(APP)"; \
		open "$(APP)"; \
	fi

clean:
	rm -rf $(DERIVED)

# Rebuild the web shell UI (WebApp/ -> Aureways/WebAppBundle). The whole main
# window is one WKWebView running this app (docs/web-shell.md). The bundle is
# committed, so normal app builds do not need Node; run this only after editing
# WebApp/src.
web:
	cd WebApp && npm ci && npm run build
