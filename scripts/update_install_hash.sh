#!/bin/sh
# Write the SHA-256 of the release DMG into site/install.sh (EXPECTED_SHA256).
# Run this after building a new DMG and before deploying the site, and deploy
# install.sh and MaruDoc.dmg together.
#
#   scripts/update_install_hash.sh [path/to/MaruDoc.dmg]
set -eu

DMG="${1:-$(dirname "$0")/../build/MaruDoc.dmg}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/../site/install.sh"

[ -f "$DMG" ] || { echo "DMG not found: $DMG" >&2; exit 1; }
[ -f "$TARGET" ] || { echo "install.sh not found: $TARGET" >&2; exit 1; }
grep -q '^EXPECTED_SHA256=' "$TARGET" || { echo "No EXPECTED_SHA256= line in $TARGET" >&2; exit 1; }

HASH="$(shasum -a 256 "$DMG" | awk '{print $1}')"
case "$HASH" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) echo "Could not compute hash" >&2; exit 1 ;;
esac

TMP="$TARGET.new"
sed "s/^EXPECTED_SHA256=.*/EXPECTED_SHA256=\"$HASH\"/" "$TARGET" > "$TMP"
chmod --reference="$TARGET" "$TMP" 2>/dev/null || chmod 644 "$TMP"
mv "$TMP" "$TARGET"

grep -q "^EXPECTED_SHA256=\"$HASH\"\$" "$TARGET" || { echo "Update failed" >&2; exit 1; }
echo "install.sh now expects $HASH"
echo "from $DMG"
