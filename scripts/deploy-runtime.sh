#!/bin/bash
# Deploy the injected runtime (Galgal.framework + OphanimAgent.dylib) from the built Ophanim.app
# to ~/Library/Frameworks, where hosted apps load it from (absolute LC_LOAD_DYLIB path).
# Clean copy (rm + ditto) so stale files never linger. Run after build-ophanim.sh.
set -euo pipefail

APPFW="$HOME/Applications/Ophanim.app/Contents/Frameworks"
DEST="$HOME/Library/Frameworks"
[ -d "$APPFW" ] || { echo "✗ $APPFW not found - build/deploy Ophanim.app first."; exit 1; }
mkdir -p "$DEST"

for item in Galgal.framework OphanimAgent.dylib; do
  if [ -e "$APPFW/$item" ]; then
    rm -rf "$DEST/$item"
    ditto "$APPFW/$item" "$DEST/$item"
    echo "✓ deployed $item → $DEST/$item"
  else
    echo "  (skip $item - not in app bundle)"
  fi
done
