#!/bin/zsh
# Direct-download release: universal build, Developer ID signature, notarization, stapled DMG.
#
# One-time setup on the Mac that holds the certificate:
#   1. Keychain has "Developer ID Application: <name> (<TEAMID>)"
#   2. xcrun notarytool store-credentials marudoc-notary --apple-id <apple-id> --team-id <TEAMID>
#      (asks for an app-specific password from appleid.apple.com)
#
# Usage:
#   SIGN_ID="Developer ID Application: <name> (<TEAMID>)" VERSION=1.0.0 BUILDNUM=1 scripts/release.sh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build}"
: "${SIGN_ID:?set SIGN_ID to your Developer ID Application identity}"
VERSION="${VERSION:-1.0.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-marudoc-notary}"

cd "$ROOT"
ARCHS=universal TIMESTAMP=1 VARIANT=direct SIGN_ID="$SIGN_ID" VERSION="$VERSION" BUILD_ROOT="$BUILD_ROOT" scripts/build_app.sh
APP="$BUILD_ROOT/dist-direct/MaruDoc.app"

echo "==> verify signature"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "network" && { echo "network entitlement found — refusing to ship"; exit 1; } || true

echo "==> notarize the app itself, so it carries its own ticket (offline first launch)"
APPZIP="$BUILD_ROOT/MaruDoc-app-notarize.zip"
[[ -f "$APPZIP" ]] && mv "$APPZIP" "$BUILD_ROOT/.old-$(date +%s)-MaruDoc-app-notarize.zip"
ditto -c -k --keepParent "$APP" "$APPZIP"
xcrun notarytool submit "$APPZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> dmg"
STAGE="$BUILD_ROOT/dmg-stage"
[[ -d "$STAGE" ]] && mv "$STAGE" "$BUILD_ROOT/.old-dmg-stage-$(date +%s)"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MaruDoc.app"
ln -s /Applications "$STAGE/Applications"
DMG="$BUILD_ROOT/MaruDoc-$VERSION.dmg"
[[ -f "$DMG" ]] && mv "$DMG" "$BUILD_ROOT/.old-$(date +%s)-MaruDoc-$VERSION.dmg"
hdiutil create -volname "MaruDoc" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

echo "==> notarize (this waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
# MaruDoc.dmg is the file attached to the GitHub release (marudoc.app/MaruDoc.dmg redirects to the latest one);
# the versioned file stays here as the archive copy. Run scripts/update_install_hash.sh afterwards.
ditto "$DMG" "$BUILD_ROOT/MaruDoc.dmg"

echo "==> done"
shasum -a 256 "$DMG"
ls -la "$DMG"
