#!/bin/zsh
# Checks the rule from Sources/EnsoApp/OverlayPanel.swift: all-Spaces windows are built there only, and the radial
# menu and the HUD never keep such a panel to order it front again later (it can be stuck on one Space).
#
#   scripts/check_overlay_windows.sh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
OVERLAY=Sources/EnsoApp/OverlayPanel.swift
failed=0

if [[ ! -f "$OVERLAY" ]]; then
  echo "error: $OVERLAY is missing" >&2
  exit 1
fi

others="$(grep -rl 'canJoinAllSpaces' Sources | grep -vxF "$OVERLAY" || true)"
if [[ -n "$others" ]]; then
  echo "error: canJoinAllSpaces is used outside $OVERLAY. Build all-Spaces windows with OverlayPanel.make:" >&2
  print -r -- "$others" | sed 's/^/  /' >&2
  failed=1
fi

reused="$(grep -nE 'panel \?\? |\?\? make' Sources/EnsoApp/RadialController.swift Sources/EnsoApp/HUD.swift || true)"
if [[ -n "$reused" ]]; then
  echo "error: an overlay panel is kept and reused ('panel ?? make...'). Build a new one each time it is shown (see $OVERLAY):" >&2
  print -r -- "$reused" | sed 's/^/  /' >&2
  failed=1
fi

(( failed == 0 )) || exit 1
echo "overlay windows OK"
