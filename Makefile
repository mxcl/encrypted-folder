APP := build/Encrypted Folder.app
CONTENTS := $(APP)/Contents
ICON := Assets/AppIcon.icon
PROFILE ?= $(HOME)/Library/MobileDevice/Provisioning Profiles/Encrypted_Folder_Developer_ID.provisionprofile
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $$2; exit }')

.PHONY: app check-launch check-touch-id install run test

app:
	@test -n "$(SIGN_IDENTITY)" || { echo 'A Developer ID Application identity is required' >&2; exit 1; }
	@test -f "$(PROFILE)" || { echo 'The Encrypted Folder Developer ID profile is required' >&2; exit 1; }
	swift build -c release --product EncryptedFolder
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp .build/release/EncryptedFolder "$(CONTENTS)/MacOS/EncryptedFolder"
	cp Sources/EncryptedFolderCore/Resources/RECOVER.command "$(CONTENTS)/Resources/RECOVER.command"
	cp Support/Info.plist "$(CONTENTS)/Info.plist"
	cp "$(PROFILE)" "$(CONTENTS)/embedded.provisionprofile"
	xcrun actool --compile "$(CONTENTS)/Resources" --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist build/AppIcon-Info.plist "$(ICON)" >/dev/null
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime --timestamp --entitlements Support/EncryptedFolder.entitlements "$(APP)"
	codesign --verify --strict --deep "$(APP)"
	@printf 'Built %s\n' "$(APP)"

install:
	./Scripts/install.sh

check-launch: app
	@set -e; "$(CONTENTS)/MacOS/EncryptedFolder" & pid=$$!; trap 'kill $$pid 2>/dev/null || true' EXIT; sleep 1; kill -0 $$pid

check-touch-id: app
	@set -e; work=$$(mktemp -d /tmp/encrypted-folder-keychain.XXXXXX); trap 'rm -rf "$$work"' EXIT; probe="$$work/KeychainProbe.app"; mkdir -p "$$probe/Contents/MacOS"; xcrun swiftc Support/KeychainProbe.swift -o "$$probe/Contents/MacOS/KeychainProbe"; cp Support/Info.plist "$$probe/Contents/Info.plist"; /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable KeychainProbe' "$$probe/Contents/Info.plist"; cp "$(PROFILE)" "$$probe/Contents/embedded.provisionprofile"; codesign --force --sign "$(SIGN_IDENTITY)" --options runtime --timestamp --entitlements Support/EncryptedFolder.entitlements "$$probe" >/dev/null; "$$probe/Contents/MacOS/KeychainProbe" --data-protection

run: app
	open "$(APP)"

test:
	swift test
