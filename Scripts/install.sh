#!/usr/local/bin/av inject +APPLE_PASSWORD +APPLE_USERNAME -- /bin/bash
# --- automic-vault
# capabilities:
#   brew: read-only
#   gh: trusted
# ---
set -euo pipefail

root="$(cd "$(dirname "${AV_SCRIPT_PATH:-$0}")/.." && pwd)"
app="$root/build/Encrypted Folder.app"
installed_app="/Applications/Encrypted Folder.app"
sign_identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')}"

die() {
  printf '%s\n' "$1" >&2
  exit 64
}

[[ -n "$sign_identity" ]] || die "A Developer ID Application certificate is required"
[[ -n "${APPLE_USERNAME:-}" ]] || die "Automic Vault did not provide APPLE_USERNAME"
[[ -n "${APPLE_PASSWORD:-}" ]] || die "Automic Vault did not provide APPLE_PASSWORD"

team_id="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
if [[ -z "$team_id" && "$sign_identity" =~ \(([A-Z0-9]+)\)$ ]]; then
  team_id="${BASH_REMATCH[1]}"
fi
[[ -n "$team_id" ]] || die "Unable to determine APPLE_TEAM_ID"

make -C "$root" app SIGN_IDENTITY="$sign_identity"

work="$(mktemp -d /tmp/encrypted-folder-install.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/dmg"
ditto "$app" "$work/dmg/Encrypted Folder.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -volname "Encrypted Folder" -srcfolder "$work/dmg" -format UDZO "$work/Encrypted Folder.dmg" >/dev/null
codesign --force --sign "$sign_identity" --timestamp "$work/Encrypted Folder.dmg"

xcrun notarytool submit \
  --apple-id "$APPLE_USERNAME" \
  --team-id "$team_id" \
  --password "$APPLE_PASSWORD" \
  --wait \
  "$work/Encrypted Folder.dmg"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
xcrun stapler staple "$work/Encrypted Folder.dmg"
xcrun stapler validate "$work/Encrypted Folder.dmg"

osascript -e 'tell application id "dev.mxcl.encrypted-folder" to quit' >/dev/null 2>&1 || true
pkill -x EncryptedFolder >/dev/null 2>&1 || true
rm -rf "$installed_app"
ditto "$app" "$installed_app"
spctl --assess --type execute --verbose=2 "$installed_app"
printf 'Installed %s\n' "$installed_app"
