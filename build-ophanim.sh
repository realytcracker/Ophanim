#!/bin/bash
# Convenience CLI build for local (ad-hoc) runs: builds the app, then deep ad-hoc re-signs so dyld
# will load it (matches the scheme's post-build action, which only runs in the Xcode GUI). Pass a
# real CODE_SIGN_IDENTITY to skip the ad-hoc re-sign.
set -euo pipefail

# Put Apple's toolchain + /usr/bin ahead of any shadowing toolchain on PATH (e.g. Anaconda's
# cctools-port vtool/strip/ld/nm/lipo, which segfault or misbehave on our Mach-O outputs).
export PATH="$(dirname "$(xcrun --find clang)"):/usr/bin:/bin:$PATH"
cd "$(dirname "$0")"

CONFIG="${1:-Release}"
xcodebuild -project Ophanim.xcodeproj -scheme Ophanim -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO \
  PROVISIONING_PROFILE_SPECIFIER="" DEVELOPMENT_TEAM="" build

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData/Ophanim-"*/Build/Products/"$CONFIG" \
        -maxdepth 1 -name Ophanim.app 2>/dev/null | head -1)"
[ -d "$APP" ] || { echo "built app not found"; exit 1; }

echo "▸ Ad-hoc deep re-sign $APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Install to ~/Applications: a stable, sudo-free location whose path satisfies the AppIntegrity
# check (it substring-matches "/Applications/Ophanim.app"), so no "move to Applications" prompt
# and no Gatekeeper translocation. Re-sign at the final destination so the on-disk sig is intact.
DEST="$HOME/Applications/Ophanim.app"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --force --deep --sign - "$DEST"
codesign --verify --deep --strict "$DEST"
echo "✓ Ophanim.app ready → $DEST"
