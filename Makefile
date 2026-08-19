APP := build/Encrypted Folder.app
CONTENTS := $(APP)/Contents

.PHONY: app run test

app:
	swift build -c release --product EncryptedFolder
	mkdir -p "$(CONTENTS)/MacOS"
	cp .build/release/EncryptedFolder "$(CONTENTS)/MacOS/EncryptedFolder"
	cp Support/Info.plist "$(CONTENTS)/Info.plist"
	codesign --force --sign - --entitlements Support/EncryptedFolder.entitlements "$(APP)"

run: app
	open "$(APP)"

test:
	swift test
