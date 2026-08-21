#!/usr/local/bin/av inject +APPLE_PASSWORD +APPLE_USERNAME -- /bin/bash
# --- automic-vault
# capabilities:
#   gh: write
# ---
# shellcheck shell=bash disable=SC1008,SC2096
set -euo pipefail

root="$(cd "$(dirname "${AV_SCRIPT_PATH:-$0}")/.." && pwd)"
app="$root/build/Encrypted Folder.app"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$root/Support/Info.plist")"
tag="v$version"
sign_identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')}"

die() {
  printf '%s\n' "$1" >&2
  exit 64
}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "The app version must be X.Y.Z"
[[ -z "$(git -C "$root" status --porcelain)" ]] || die "Commit or stash changes before publishing"
[[ -n "$sign_identity" ]] || die "A Developer ID Application certificate is required"
[[ -n "${APPLE_USERNAME:-}" ]] || die "Automic Vault did not provide APPLE_USERNAME"
[[ -n "${APPLE_PASSWORD:-}" ]] || die "Automic Vault did not provide APPLE_PASSWORD"
gh release view "$tag" >/dev/null 2>&1 && die "GitHub release $tag already exists"

make -C "$root" app SIGN_IDENTITY="$sign_identity"

work="$(mktemp -d /tmp/encrypted-folder-publish.XXXXXX)"
trap 'rm -rf "$work"' EXIT
dmg="$work/Encrypted-Folder-$version.dmg"
mkdir "$work/dmg"
ditto "$app" "$work/dmg/Encrypted Folder.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -volname "Encrypted Folder" -srcfolder "$work/dmg" -format UDZO "$dmg" >/dev/null
codesign --force --sign "$sign_identity" --timestamp "$dmg"

team_id="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
if [[ -z "$team_id" && "$(codesign -dv --verbose=4 "$app" 2>&1)" =~ TeamIdentifier=([A-Z0-9]+) ]]; then
  team_id="${BASH_REMATCH[1]}"
fi
[[ -n "$team_id" ]] || die "Unable to determine APPLE_TEAM_ID"

xcrun notarytool submit --apple-id "$APPLE_USERNAME" --team-id "$team_id" --password "$APPLE_PASSWORD" --wait "$dmg"
xcrun stapler staple "$app"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

gh release create "$tag" "$dmg" \
  --target "$(git -C "$root" rev-parse HEAD)" \
  --title "Encrypted Folder $version" \
  --generate-notes \
  --latest
