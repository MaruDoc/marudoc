#!/bin/sh
# MaruDoc installer for macOS.
#
#   curl -fsSL https://marudoc.app/install.sh | sh
#
# This script downloads the notarized MaruDoc.dmg, checks its SHA-256, mounts it,
# checks the app's signature and notarization, and copies MaruDoc.app into
# /Applications. It does not use sudo and never deletes your files: an existing
# copy is moved to ~/.Trash. Only its own download folder is removed at the end.
#
# Options (pass after "sh -s --" when piping):
#   --uninstall   quit MaruDoc, move it to the Trash, turn off its Finder extension
#   --help        show this help
#
# Environment variables:
#   MARUDOC_DMG_URL      download URL (default: https://marudoc.app/MaruDoc.dmg)
#   MARUDOC_INSTALL_DIR  where to install (default: /Applications)
#   MARUDOC_NO_OPEN=1    do not launch MaruDoc after installing
#
# If MARUDOC_INSTALL_DIR is neither /Applications nor ~/Applications, the app is
# copied but not registered with LaunchServices or pluginkit. This keeps test
# copies from adding a second Finder extension entry.
#
# EXPECTED_SHA256 is the hash of the current MaruDoc.dmg. It is written by
# scripts/update_install_hash.sh. Do not edit it by hand.

set -eu

EXPECTED_SHA256="6b2262c44ac3f8889da1c2f965f73e105a3856b71deeb14646963dde714dea37"

DMG_URL="${MARUDOC_DMG_URL:-https://marudoc.app/MaruDoc.dmg}"
INSTALL_DIR="${MARUDOC_INSTALL_DIR:-/Applications}"
NO_OPEN="${MARUDOC_NO_OPEN:-0}"

APP_NAME="MaruDoc.app"
BUNDLE_ID="app.marudoc.MaruDoc"
EXT_ID="app.marudoc.MaruDoc.FinderSync"
APPEX_REL="Contents/PlugIns/MaruDocFinder.appex"
TEAM_ID="FC2V887B8C"
MIN_MACOS=14
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

MNT=""
WORK=""

say() {
  # say "日本語" "English"
  printf '%s\n%s\n' "$1" "$2"
}

die() {
  printf '\n' >&2
  printf 'エラー: %s\n' "$1" >&2
  printf 'Error: %s\n' "$2" >&2
  exit 1
}

detach() {
  if [ -n "$MNT" ] && [ -d "$MNT" ]; then
    hdiutil detach "$MNT" -quiet </dev/null >/dev/null 2>&1 \
      || hdiutil detach "$MNT" -force -quiet </dev/null >/dev/null 2>&1 \
      || true
    MNT=""
  fi
}

# Remove the download folder this script created (nothing else).
cleanup() {
  detach
  case "$WORK" in
    "${TMPDIR:-/tmp}"/marudoc.*|/tmp/marudoc.*) rm -rf "$WORK" ;;
  esac
  WORK=""
}

usage() {
  cat <<'EOF'
MaruDoc installer / MaruDoc インストーラ

  curl -fsSL https://marudoc.app/install.sh | sh
  curl -fsSL https://marudoc.app/install.sh | sh -s -- --uninstall

Environment variables / 環境変数:
  MARUDOC_DMG_URL      DMG の URL / download URL
  MARUDOC_INSTALL_DIR  インストール先 (既定 /Applications) / install location
  MARUDOC_NO_OPEN=1    インストール後に起動しない / do not launch afterwards

/Applications に入れる権限がないときは、sudo を使わずに次のように実行してください。
If /Applications is not writable, run this instead of using sudo:
  curl -fsSL https://marudoc.app/install.sh | MARUDOC_INSTALL_DIR=~/Applications sh
EOF
}

plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

is_running() {
  [ "$(osascript -e "application id \"$BUNDLE_ID\" is running" </dev/null 2>/dev/null || echo false)" = "true" ]
}

# Ask a running MaruDoc to quit and wait up to 10 seconds.
quit_app() {
  is_running || return 0
  say "MaruDoc を終了しています。" "Quitting MaruDoc."
  osascript -e "with timeout of 5 seconds
tell application id \"$BUNDLE_ID\" to quit
end timeout" </dev/null >/dev/null 2>&1 || true
  i=0
  while is_running && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
  done
  if is_running; then
    die "MaruDoc が終了しませんでした。手動で終了してからもう一度実行してください。" \
        "MaruDoc did not quit. Quit it manually and run this again."
  fi
}

# Move a path into ~/.Trash under a unique name. Prints the new path.
move_to_trash() {
  trash="$HOME/.Trash"
  mkdir -p "$trash"
  dest="$trash/MaruDoc-$(date +%Y%m%d-%H%M%S).app"
  n=1
  while [ -e "$dest" ]; do
    dest="$trash/MaruDoc-$(date +%Y%m%d-%H%M%S)-$n.app"
    n=$((n + 1))
  done
  mv "$1" "$dest"
  printf '%s\n' "$dest"
}

# Register with LaunchServices and pluginkit only for the standard locations.
standard_location() {
  case "$INSTALL_DIR" in
    /Applications|/Applications/|"$HOME/Applications"|"$HOME/Applications/") return 0 ;;
    *) return 1 ;;
  esac
}

do_uninstall() {
  target="$INSTALL_DIR/$APP_NAME"
  if [ ! -d "$target" ]; then
    say "$target が見つかりません。" "$target was not found."
  else
    quit_app
    trashed="$(move_to_trash "$target")"
    say "MaruDoc をゴミ箱に移しました: $trashed" "Moved MaruDoc to the Trash: $trashed"
  fi
  if standard_location; then
    pluginkit -e ignore -i "$EXT_ID" </dev/null >/dev/null 2>&1 || true
    say "Finder 拡張を無効にしました。" "Turned off the Finder extension."
  else
    say "標準の場所ではないため、Finder 拡張の設定は変更していません。" \
        "Not a standard location, so the Finder extension setting was left alone."
  fi
}

do_install() {
  # 1. Requirements
  if [ "$(uname -s)" != "Darwin" ]; then
    die "MaruDoc は macOS 専用です。" "MaruDoc runs on macOS only."
  fi
  os_ver="$(sw_vers -productVersion)"
  os_major="${os_ver%%.*}"
  case "$os_major" in
    ''|*[!0-9]*) die "macOS のバージョンを判定できません: $os_ver" "Cannot read the macOS version: $os_ver" ;;
  esac
  if [ "$os_major" -lt "$MIN_MACOS" ]; then
    die "macOS $MIN_MACOS 以降が必要です (現在 $os_ver)。" "macOS $MIN_MACOS or later is required (this Mac has $os_ver)."
  fi
  if [ -z "$EXPECTED_SHA256" ]; then
    die "このスクリプトにチェックサムが設定されていません。" "This script has no expected checksum set."
  fi

  # 2. Target directory
  mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  if [ ! -d "$INSTALL_DIR" ] || [ ! -w "$INSTALL_DIR" ]; then
    say "$INSTALL_DIR に書き込めません。sudo は使わず、次のように実行してください。" \
        "Cannot write to $INSTALL_DIR. Do not use sudo; run this instead:"
    echo "  curl -fsSL https://marudoc.app/install.sh | MARUDOC_INSTALL_DIR=~/Applications sh"
    exit 1
  fi

  # 3. Download
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/marudoc.XXXXXX")"
  trap cleanup EXIT
  dmg="$WORK/MaruDoc.dmg"
  say "MaruDoc をダウンロードしています。" "Downloading MaruDoc."
  if [ -t 2 ]; then progress="--progress-bar"; else progress="-sS"; fi
  curl -fL --retry 3 --proto '=https' --proto-redir '=https' --tlsv1.2 "$progress" \
    -o "$dmg" "$DMG_URL" </dev/null \
    || die "ダウンロードに失敗しました: $DMG_URL" "Download failed: $DMG_URL"

  # 4. SHA-256
  actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  if [ "$actual" != "$EXPECTED_SHA256" ]; then
    printf '  expected: %s\n  actual:   %s\n' "$EXPECTED_SHA256" "$actual" >&2
    die "チェックサムが一致しません。インストールを中止しました。" \
        "Checksum mismatch. Installation aborted."
  fi
  say "チェックサムを確認しました。" "Checksum verified."

  # 5. Mount
  MNT="$WORK/mnt"
  mkdir "$MNT"
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$MNT" -quiet </dev/null >/dev/null \
    || { MNT=""; die "DMG をマウントできません。" "Could not mount the disk image."; }
  src="$MNT/$APP_NAME"
  [ -d "$src" ] || die "DMG の中に $APP_NAME が見つかりません。" "$APP_NAME is not in the disk image."

  # 6. Verify the app inside
  say "署名と公証を確認しています。" "Checking signature and notarization."
  codesign --verify --deep --strict "$src" </dev/null >/dev/null 2>&1 \
    || die "コード署名が正しくありません。" "Code signature is not valid."
  team="$(codesign -dv --verbose=2 "$src" 2>&1 </dev/null | sed -n 's/^TeamIdentifier=//p')"
  [ "$team" = "$TEAM_ID" ] \
    || die "開発元が想定と異なります (Team ID: ${team:-なし/none})。" "Unexpected developer (Team ID: ${team:-none})."
  bid="$(plist_get "$src/Contents/Info.plist" CFBundleIdentifier || true)"
  [ "$bid" = "$BUNDLE_ID" ] \
    || die "Bundle ID が想定と異なります ($bid)。" "Unexpected bundle identifier ($bid)."
  assess="$(spctl -a -t exec -vv "$src" 2>&1 </dev/null || true)"
  case "$assess" in
    *": accepted"*) ;;
    *) die "Gatekeeper がこのアプリを許可しませんでした。" "Gatekeeper did not accept this app." ;;
  esac
  case "$assess" in
    *"source=Notarized Developer ID"*) ;;
    *) die "公証済みの Developer ID ではありません。" "The app is not a notarized Developer ID app." ;;
  esac
  if command -v xcrun >/dev/null 2>&1; then
    xcrun stapler validate "$src" </dev/null >/dev/null 2>&1 \
      || die "公証チケットの検証に失敗しました。" "Notarization ticket validation failed."
  fi
  version="$(plist_get "$src/Contents/Info.plist" CFBundleShortVersionString || true)"
  build="$(plist_get "$src/Contents/Info.plist" CFBundleVersion || true)"

  # 7. Replace an existing copy
  target="$INSTALL_DIR/$APP_NAME"
  stage="$INSTALL_DIR/.MaruDoc-install.$$.app"
  if [ -d "$target" ]; then
    quit_app
  fi
  say "$INSTALL_DIR にコピーしています。" "Copying to $INSTALL_DIR."
  ditto "$src" "$stage" </dev/null \
    || die "コピーに失敗しました ($stage が残っている場合は削除してください)。" \
           "Copy failed (if $stage remains, you can delete it)."
  if [ -d "$target" ]; then
    trashed="$(move_to_trash "$target")"
    say "古いバージョンをゴミ箱に移しました: $trashed" "Moved the old copy to the Trash: $trashed"
  fi
  mv "$stage" "$target"
  detach
  codesign --verify --deep --strict "$target" </dev/null >/dev/null 2>&1 \
    || die "コピー後の署名確認に失敗しました。" "Signature check failed after copying."

  # 8. Register
  if standard_location; then
    "$LSREGISTER" -f "$target" </dev/null >/dev/null 2>&1 || true
    pluginkit -a "$target/$APPEX_REL" </dev/null >/dev/null 2>&1 || true
    pluginkit -e use -i "$EXT_ID" </dev/null >/dev/null 2>&1 || true
  else
    say "標準の場所ではないため、システムへの登録は省略しました。" \
        "Not a standard location, so system registration was skipped."
  fi

  # 9. Launch
  if [ "$NO_OPEN" != "1" ]; then
    open "$target" </dev/null >/dev/null 2>&1 \
      || say "自動で起動できませんでした。手動で開いてください。" "Could not launch it automatically. Open it manually."
  fi

  # 10. Summary
  echo
  say "インストールしました: $target (バージョン ${version:-?}, ビルド ${build:-?})" \
      "Installed: $target (version ${version:-?}, build ${build:-?})"
  echo
  say "機能を初めて使うときに、次の許可を求められます。システム設定でご自身で許可してください。" \
      "MaruDoc asks for these permissions when you first use the feature that needs them. You turn them on in System Settings."
  say "1. Finder 拡張 (右クリックメニュー): 一般 > ログイン項目と機能拡張 > Finder" \
      "1. Finder extension (right-click menu): General > Login Items & Extensions > Finder"
  say "2. アクセシビリティ (長押しメニュー。使わないなら不要): プライバシーとセキュリティ > アクセシビリティ" \
      "2. Accessibility (press-and-hold menu; not needed if you don't use it): Privacy & Security > Accessibility"
  say "3. オートメーション (デスクトップに結果を置く): MaruDoc から Finder の操作を許可" \
      "3. Automation (placing results on the desktop): allow MaruDoc to control Finder"
}

main() {
  case "${1:-}" in
    "") do_install ;;
    --uninstall) do_uninstall ;;
    --help|-h) usage ;;
    *)
      usage >&2
      die "不明なオプション: $1" "Unknown option: $1"
      ;;
  esac
}

main "$@"
