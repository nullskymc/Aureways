DERIVED ?= .derived
SCHEME ?= Aureways

# Optional. Defaults to `xcode-select -p`.
# make open DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
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
