#!/bin/bash
# Builds OphanimTest.ipa - a kitchen-sink iOS app that exercises every category Ophanim hooks.
# Drop the resulting .ipa into Ophanim to install/inject, enable instrumentation, launch, and view
# the captured events. Built for iOS device (arm64); Ophanim converts it to Mac Catalyst on install.
set -euo pipefail

# Put Apple's toolchain + /usr/bin ahead of any shadowing toolchain on PATH (e.g. Anaconda's
# cctools-port vtool/strip/ld/nm/lipo, which segfault or misbehave on our Mach-O outputs).
export PATH="$(dirname "$(xcrun --find clang)"):/usr/bin:/bin:$PATH"
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios15.0"
OUT="build"; APP="$OUT/Payload/OphanimTest.app"
rm -rf "$OUT"; mkdir -p "$APP"

echo "▸ Compiling (iphoneos arm64)…"
swiftc -sdk "$SDK" -target "$TARGET" -parse-as-library -O \
  Sources/*.swift -o "$APP/OphanimTest" \
  -framework UIKit -framework Foundation -framework Security \
  -framework AdSupport -framework CoreLocation -framework DeviceCheck

cp Info.plist "$APP/Info.plist"

echo "▸ Compiling app icon (actool)…"
PARTIAL="$OUT/asset-info.plist"
actool Assets.xcassets --compile "$APP" --platform iphoneos \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --target-device iphone --target-device ipad \
  --output-partial-info-plist "$PARTIAL" >/dev/null
# Merge actool's icon keys (CFBundleIcons / CFBundleIconName) into the bundle Info.plist.
python3 - "$APP/Info.plist" "$PARTIAL" <<'PY'
import plistlib, sys
appp, partp = sys.argv[1], sys.argv[2]
app = plistlib.load(open(appp, "rb"))
part = plistlib.load(open(partp, "rb"))
app.update(part)
plistlib.dump(app, open(appp, "wb"))
print("merged icon keys:", ", ".join(part.keys()))
PY

echo "▸ Ad-hoc signing bundle…"
codesign --force --sign - "$APP"

echo "▸ Packaging .ipa…"
( cd "$OUT" && zip -qr OphanimTest.ipa Payload )
echo "✓ $(cd "$OUT" && pwd)/OphanimTest.ipa"
