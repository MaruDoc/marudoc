#!/bin/bash
# Copies the public subset of this project into a separate folder, ready for `git init`.
#
#   scripts/export_public.sh [export-dir]
#
# Default export-dir: <LOCAL_ROOT>/public-repo (LOCAL_ROOT is set near the top)
#
# The source project is never modified. Only an explicit allow-list is copied, and
# a few patches are applied to the exported copy only:
#   - Package.swift drops the officetest / pdftest harnesses (they use machine-local
#     paths and need LibreOffice)
#   - scripts/*.sh get a build output default of <project>/build instead of a local volume
# Re-running updates the export. rsync --delete is used only inside the allow-listed
# directories of the export folder; .git and anything else in it is left alone.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_ROOT=""
DEST="${1:-${LOCAL_ROOT:-$SRC/..}/public-repo}"

case "$DEST" in
  ""|"/"|"$HOME"|"$SRC"|"$SRC"/*) echo "refusing export dir: $DEST" >&2; exit 1 ;;
esac
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
[[ "$DEST" == "$SRC" || "$DEST" == "$SRC"/* ]] && { echo "refusing export dir inside the source: $DEST" >&2; exit 1; }

EXCLUDES=(
  --exclude='.build' --exclude='.swiftpm' --exclude='.DS_Store' --exclude='._*'
  --exclude='*.dmg' --exclude='*.pkg' --exclude='*.zip'
  --exclude='*.p8' --exclude='*.p12' --exclude='*.cer' --exclude='*.certSigningRequest'
  --exclude='*.provisionprofile' --exclude='*.mobileprovision' --exclude='AuthKey_*'
  --exclude='*scan*report*' --exclude='*security-report*' --exclude='*SCAN_REPORT*'
)

echo "==> export $SRC -> $DEST"

# Directories: mirrored (with --delete inside the destination subdirectory only).
for d in Sources Resources scripts site; do
  [[ -d "$SRC/$d" ]] || { echo "missing $d" >&2; exit 1; }
  mkdir -p "$DEST/$d"
  extra=()
  # Test harnesses: not portable (absolute local paths, LibreOffice profiles).
  [[ "$d" == Sources ]] && extra=(--exclude='/officetest' --exclude='/pdftest')
  rsync -a --delete "${EXCLUDES[@]}" ${extra[@]+"${extra[@]}"} "$SRC/$d/" "$DEST/$d/"
done

# docs: only the security Q&A.
mkdir -p "$DEST/docs"
rsync -a --delete --include='08_セキュリティQ&A.md' --exclude='*' "$SRC/docs/" "$DEST/docs/"

# Top-level files.
for f in Package.swift README.md LICENSE SECURITY.md CONTRIBUTING.md .gitignore; do
  [[ -f "$SRC/$f" ]] || { echo "missing $f" >&2; exit 1; }
  rsync -a "$SRC/$f" "$DEST/$f"
done

# --- patches on the exported copy only ---
# Package.swift: drop the two harness products and targets (and their comment line).
sed -i '' -e '/"officetest"/d' -e '/"pdftest"/d' -e '/Developer test harnesses/d' "$DEST/Package.swift"
if grep -qE 'officetest|pdftest' "$DEST/Package.swift"; then echo "Package.swift patch failed" >&2; exit 1; fi

# scripts: no machine-specific default output folder; this script's own default is blanked too.
if [[ -n "$LOCAL_ROOT" ]]; then
  for s in build_app.sh release.sh appstore.sh; do
    sed -i '' "s#\${BUILD_ROOT:-$LOCAL_ROOT}#\${BUILD_ROOT:-\$ROOT/build}#" "$DEST/scripts/$s"
  done
  sed -i '' "s#\${1:-$LOCAL_ROOT/MaruDoc.dmg}#\${1:-\$(dirname \"\$0\")/../build/MaruDoc.dmg}#" "$DEST/scripts/update_install_hash.sh"
  sed -i '' 's#^LOCAL_ROOT=.*#LOCAL_ROOT=""#' "$DEST/scripts/export_public.sh"
fi

if grep -rIn '/Volume[s]/' "$DEST/Sources" "$DEST/scripts" "$DEST/Package.swift" >&2; then
  echo "warning: local path still present in export" >&2
fi
echo "==> done"
