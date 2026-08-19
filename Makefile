APP := build/Encrypted Folder.app
CONTENTS := $(APP)/Contents
ICON := Assets/AppIcon.icon
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $$2; exit }')
SIGNER := $(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)
SIGN_OPTIONS := $(if $(SIGN_IDENTITY),--options runtime --timestamp,)

.PHONY: app install run test

app:
	swift build -c release --product EncryptedFolder
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp .build/release/EncryptedFolder "$(CONTENTS)/MacOS/EncryptedFolder"
	cp Support/Info.plist "$(CONTENTS)/Info.plist"
	xcrun actool --compile "$(CONTENTS)/Resources" --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist build/AppIcon-Info.plist "$(ICON)" >/dev/null
	codesign --force --sign "$(SIGNER)" $(SIGN_OPTIONS) --entitlements Support/EncryptedFolder.entitlements "$(APP)"
	codesign --verify --strict --deep "$(APP)"
	@printf 'Built %s\n' "$(APP)"

install:
	./Scripts/install.sh

run: app
	open "$(APP)"

test:
	swift test
