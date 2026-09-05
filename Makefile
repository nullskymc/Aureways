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
# command-line builds do not stall on approval. SwiftStreamingMarkdown pulls in
# ordo-one/equatable, a swift-syntax macro package, which needs the macro
# equivalent of that flag for the same reason.
XCBUILD_FLAGS := -skipPackagePluginValidation -skipMacroValidation
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
