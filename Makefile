DERIVED ?= .derived
SCHEME ?= Aureways

# Command Line Tools does not ship xcodebuild. Prefer a full Xcode.app if
# DEVELOPER_DIR is unset/missing, or xcode-select points at CommandLineTools or missing path.
ifeq ($(wildcard $(DEVELOPER_DIR)),)
DEVELOPER_DIR :=
endif

ifeq ($(DEVELOPER_DIR),)
XCODE_SELECT := $(shell xcode-select -p 2>/dev/null)
NEED_FALLBACK :=
ifneq ($(findstring CommandLineTools,$(XCODE_SELECT)),)
NEED_FALLBACK := 1
endif
ifeq ($(wildcard $(XCODE_SELECT)),)
NEED_FALLBACK := 1
endif
ifeq ($(NEED_FALLBACK),1)
XCODE_CANDIDATES := \
	/Applications/Xcode.app \
	/Applications/Xcode-beta.app \
	/Volumes/Data/Applications/Xcode.app \
	/Volumes/Data/Applications/Xcode-beta.app \
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
