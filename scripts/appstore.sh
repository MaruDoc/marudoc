#!/bin/zsh
# Mac App Store package: sandboxed variant (-D APPSTORE), Apple Distribution signature, installer package.
#
# Needs (from developer.apple.com, team TEAM_ID):
#   - App IDs app.marudoc.MaruDoc and app.marudoc.MaruDoc.FinderSync, and Mac App Store provisioning profiles for both
#   - "Apple Distribution: …" and "3rd Party Mac Developer Installer: …" (or "Mac Installer Distribution: …") certificates
# Upload the resulting .pkg with Apple's Transporter app.
#
# Usage:
#   TEAM_ID=XXXXXXXXXX SIGN_ID="Apple Distribution: Yitao Ding (XXXXXXXXXX)" \
#   INSTALLER_ID="3rd Party Mac Developer Installer: Yitao Ding (XXXXXXXXXX)" \
#   APP_PROFILE=~/Downloads/MaruDoc_MAS.provisionprofile EXT_PROFILE=~/Downloads/MaruDocFinder_MAS.provisionprofile \
#   VERSION=1.0.0 BUILDNUM=1 scripts/appstore.sh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build}"
: "${TEAM_ID:?}" "${SIGN_ID:?}" "${INSTALLER_ID:?}" "${APP_PROFILE:?}" "${EXT_PROFILE:?}"
VERSION="${VERSION:-1.0.0}"
cd "$ROOT"

# The store requires application-identifier / team-identifier entitlements that match the profiles.
GEN="$BUILD_ROOT/appstore-entitlements"; mkdir -p "$GEN"
add_ids() { # in out bundle-id
  cp "$1" "$2"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$3" "$2"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$2"
}
add_ids Resources/App/MaruDoc-AppStore.entitlements "$GEN/MaruDoc.entitlements" app.marudoc.MaruDoc
add_ids Resources/FinderSync/MaruDocFinder.entitlements "$GEN/MaruDocFinder.entitlements" app.marudoc.MaruDoc.FinderSync

ARCHS=universal TIMESTAMP=1 VARIANT=appstore SIGN_ID="$SIGN_ID" VERSION="$VERSION" BUILD_ROOT="$BUILD_ROOT" \
  APP_ENTITLEMENTS="$GEN/MaruDoc.entitlements" EXT_ENTITLEMENTS="$GEN/MaruDocFinder.entitlements" \
  APP_PROFILE="$APP_PROFILE" EXT_PROFILE="$EXT_PROFILE" scripts/build_app.sh
APP="$BUILD_ROOT/dist-appstore/MaruDoc.app"

echo "==> check: sandboxed, no network"
codesign -d --entitlements - "$APP" | grep -q "app-sandbox" || { echo "not sandboxed"; exit 1; }
codesign -d --entitlements - "$APP" | grep -q "application-groups" || { echo "app group entitlement missing"; exit 1; }
codesign -d --entitlements - "$APP/Contents/PlugIns/MaruDocFinder.appex" 2>/dev/null | grep -q "application-groups" || { echo "app group entitlement missing in Finder extension"; exit 1; }
codesign -d --entitlements - "$APP" | grep -q "network" && { echo "network entitlement present"; exit 1; } || true

PKG="$BUILD_ROOT/MaruDoc-$VERSION-AppStore.pkg"
productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
echo "==> $PKG  (upload with Transporter)"
