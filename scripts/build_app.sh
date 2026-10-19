#!/bin/zsh
# Builds MaruDoc.app without Xcode: SwiftPM compiles the two executables, this script assembles and signs the bundle.
#
#   scripts/build_app.sh                       # release, this Mac's arch, ad-hoc signed, into $BUILD_ROOT/dist
#   ARCHS=universal scripts/build_app.sh       # arm64 + x86_64
#   VARIANT=appstore scripts/build_app.sh      # sandboxed Mac App Store variant (-D APPSTORE)
#   SIGN_ID="Developer ID Application: ..." scripts/build_app.sh
#   INSTALL=1 scripts/build_app.sh             # also install into /Applications and register the Finder extension
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build}"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-1.0.0}"
BUILDNUM="${BUILDNUM:-1}"
SIGN_ID="${SIGN_ID:--}"
ARCHS="${ARCHS:-native}"
VARIANT="${VARIANT:-direct}"
SCRATCH="$BUILD_ROOT/app-$CONFIG-$VARIANT"
DIST="$BUILD_ROOT/dist-$VARIANT"

cd "$ROOT"
swift_args=(-c "$CONFIG" --scratch-path "$SCRATCH")
[[ "$ARCHS" == universal ]] && swift_args+=(--arch arm64 --arch x86_64)
[[ "$VARIANT" == appstore ]] && swift_args+=(-Xswiftc -DAPPSTORE)

echo "==> swift build ($CONFIG, $ARCHS, $VARIANT)"
swift build "${swift_args[@]}" --product EnsoApp
swift build "${swift_args[@]}" --product EnsoFinderSync
BIN="$(swift build "${swift_args[@]}" --show-bin-path)"

APP="$DIST/MaruDoc.app"
APPEX="$APP/Contents/PlugIns/MaruDocFinder.appex"
mkdir -p "$DIST"
if [[ -d "$APP" ]]; then mv "$APP" "$BUILD_ROOT/.old-$(date +%s)-MaruDoc.app"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

ditto "$BIN/EnsoApp" "$APP/Contents/MacOS/MaruDoc"
ditto "$BIN/EnsoFinderSync" "$APPEX/Contents/MacOS/MaruDocFinder"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILDNUM/" Resources/App/Info.plist > "$APP/Contents/Info.plist"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILDNUM/" Resources/FinderSync/Info.plist > "$APPEX/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
ditto Resources/App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Compiled asset catalog (the Mac App Store requires one). Rebuild with actool from Xcode when the icon changes.
ditto Resources/App/Assets.car "$APP/Contents/Resources/Assets.car"
for lproj in Resources/App/*.lproj; do ditto "$lproj" "$APP/Contents/Resources/${lproj:t}"; done

EXT_ENT="${EXT_ENTITLEMENTS:-Resources/FinderSync/MaruDocFinder.entitlements}"
if [[ "$VARIANT" == appstore ]]; then
  APP_ENT="${APP_ENTITLEMENTS:-Resources/App/MaruDoc-AppStore.entitlements}"
  [[ -n "${APP_PROFILE:-}" ]] && ditto "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
  [[ -n "${EXT_PROFILE:-}" ]] && ditto "$EXT_PROFILE" "$APPEX/Contents/embedded.provisionprofile"
else
  APP_ENT=Resources/App/MaruDoc.entitlements
fi

sign_args=(--force --sign "$SIGN_ID" --options runtime)
# Secure timestamps only for real Developer ID / distribution signing (TIMESTAMP=1).
if [[ "${TIMESTAMP:-0}" == 1 ]]; then sign_args+=(--timestamp); else sign_args+=(--timestamp=none); fi
echo "==> codesign ($SIGN_ID)"
codesign "${sign_args[@]}" --entitlements "$EXT_ENT" "$APPEX"
codesign "${sign_args[@]}" --entitlements "$APP_ENT" "$APP"
codesign --verify --strict --deep "$APP"
echo "==> built $APP"

if [[ "${INSTALL:-0}" == 1 ]]; then
  # Quit the old Enso (com.yd.enso) and MaruDoc. An editor with unsaved changes holds the quit behind its alert,
  # so the AppleEvent can time out; in that case the running process must not be replaced under the user.
  quit_app() { # bundle-id, executable path, display name
    if pgrep -f "$2" >/dev/null 2>&1; then
      echo "==> asking the running $3 to quit"
      osascript -e 'with timeout of 3 seconds' -e "tell application id \"$1\" to quit" -e 'end timeout' >/dev/null 2>&1 || true
      for _ in {1..20}; do
        pgrep -f "$2" >/dev/null 2>&1 || break
        sleep 0.5
      done
      if pgrep -f "$2" >/dev/null 2>&1; then
        echo "error: $3 is still running, probably because an editor has unsaved changes." >&2
        echo "       Save or discard them in $3, quit it, and run again. Nothing was installed." >&2
        exit 1
      fi
    fi
  }
  quit_app com.yd.enso /Applications/Enso.app/Contents/MacOS/Enso Enso
  quit_app app.marudoc.MaruDoc /Applications/MaruDoc.app/Contents/MacOS/MaruDoc MaruDoc
  # The old app goes to the Trash, and its Finder extension is switched off so Finder shows one menu.
  if [[ -d /Applications/Enso.app ]]; then mv /Applications/Enso.app "$HOME/.Trash/Enso-$(date +%s).app"; fi
  pluginkit -e ignore -i com.yd.enso.FinderSync || true
  if [[ -d /Applications/MaruDoc.app ]]; then mv /Applications/MaruDoc.app "$HOME/.Trash/MaruDoc-$(date +%s).app"; fi
  ditto "$APP" /Applications/MaruDoc.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MaruDoc.app
  pluginkit -a /Applications/MaruDoc.app/Contents/PlugIns/MaruDocFinder.appex
  pluginkit -e use -i app.marudoc.MaruDoc.FinderSync
  echo "==> installed /Applications/MaruDoc.app"
fi
