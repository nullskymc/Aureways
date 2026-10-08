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

.PHONY: build release test open clean web web-test

# WebAppBundle is a folder reference in the Xcode project. It is build output,
# not source: compile it before xcodebuild copies it into the app.
WEB_BUNDLE := Aureways/WebAppBundle
WEB_STAMP := $(WEB_BUNDLE)/.stamp
WEB_MODULES_STAMP := WebApp/node_modules/.install-stamp
WEB_INPUTS := $(shell find WebApp/src WebApp/scripts -type f) \
	WebApp/index.html \
	WebApp/package.json \
	WebApp/package-lock.json \
	WebApp/vite.config.ts \
	WebApp/tsconfig.json

$(WEB_MODULES_STAMP): WebApp/package.json WebApp/package-lock.json
	cd WebApp && npm ci
	@touch $@

$(WEB_STAMP): $(WEB_MODULES_STAMP) $(WEB_INPUTS)
	cd WebApp && npm run build
	@touch $@

web: $(WEB_STAMP)

web-test: $(WEB_MODULES_STAMP)
	cd WebApp && npm test

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

build: web
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) build

release: web
	xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) build

# The test host is the Debug app, which shares the bundle id (and so the
# session DB and quota cache) with the installed build. Redirect only the
# app's own data directory, not the whole home: TEST_RUNNER_CFFIXED_USER_HOME
# also rewrites HOME and USER, and a login shell started by the terminal tests
# then reads startup files under a home that doesn't exist and exits before
# running the command (GrokTerminalEndToEndTests failed that way in CI).
TEST_DATA ?= /tmp/aureways-test-data

test: web web-test
	rm -rf "$(TEST_DATA)" && mkdir -p "$(TEST_DATA)"
	TEST_RUNNER_CFFIXED_USER_HOME_DIR="$(TEST_DATA)" xcodebuild -project Aureways.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XCBUILD_FLAGS) test

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
	rm -rf $(DERIVED) $(WEB_BUNDLE)
