#!/bin/bash
# Local rehearsal by default only when explicitly requested; never publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { echo 'Usage: scripts/release.sh --dry-run | --notarize (uploads to Apple; requires explicit authorization)' >&2; }
if [[ $# != 1 ]]; then usage; exit 2; fi
case "$1" in
  --dry-run) mode=dry-run ;;
  --notarize) mode=notarize ;;
  *) usage; exit 2 ;;
esac
if [[ "$mode" == notarize ]]; then
  : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Keychain signing identity}"
  : "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to a notarytool Keychain profile}"
  [[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application: '* ]] || { echo 'Use a Developer ID Application identity.' >&2; exit 2; }
fi
scripts/make_app.sh --universal
version=$(<VERSION)
arch=universal
app=build/Saga.app
out="build/release/$mode"
mkdir -p "$out"
stage=$(mktemp -d "$PWD/build/release/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
if [[ "$mode" == notarize ]]; then
  # Sign nested executable first, then the enclosing app. Do not use --deep to sign.
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app/Contents/MacOS/saga-mcp"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app"
  codesign --verify --deep --strict "$app"
  ditto -c -k --keepParent "$app" "$stage/Saga.zip"
  xcrun notarytool submit "$stage/Saga.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose "$app"
fi
ditto "$app" "$stage/Saga.app"
cp LICENSE "$stage/LICENSE.txt"
# The one thing most people will actually read: how to get past Gatekeeper.
# Staged into every DMG at top level so it is beside the app in the window.
# It cannot carry the DMG's own SHA-256 (a file cannot contain the checksum of
# the container it is inside), so it points at the published Saga.sha256.
sed "s/__VERSION__/$version/" Resources/ReadMeFirst.txt > "$stage/Read me first.txt"
ln -s /Applications "$stage/Applications"
# Never package the repository, app-support folder, or a user's vault.
rm -f "$stage/Saga.zip"
dmg="$out/Saga-$version-$arch.dmg"
hdiutil create -volname "Saga $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
hdiutil verify "$dmg"
if [[ "$mode" == notarize ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
shasum -a 256 "$dmg" > "$dmg.sha256"
echo "Prepared $dmg ($mode); no tag, push, or release published."
if [[ "$mode" == dry-run ]]; then echo 'LOCAL REHEARSAL ONLY: ad-hoc signed, not notarized, not for distribution.'; fi
