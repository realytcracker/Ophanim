#!/bin/bash
# Builds the standalone Ophanim agent dylib (sibling injection mode) from the shared OphanimCore
# sources + the ObjC constructor, retags it to Mac Catalyst, ad-hoc signs, and stages it next to
# the Galgal framework so the app can inject it via a second LC_LOAD_DYLIB.
# Output: <app>/Carthage/Build/Galgal.xcframework/ios-arm64/OphanimAgent.dylib
set -euo pipefail

# Put Apple's toolchain + /usr/bin ahead of any shadowing toolchain on PATH (e.g. Anaconda's
# cctools-port vtool/strip/ld/nm/lipo, which segfault or misbehave on our Mach-O outputs).
export PATH="$(dirname "$(xcrun --find clang)"):/usr/bin:/bin:$PATH"

cd "$(dirname "$0")"                       # .../Ophanim/Galgal
APP_ROOT="$(cd .. && pwd)"
CORE="$APP_ROOT/OphanimCore"
STAGE="$APP_ROOT/Carthage/Build/Galgal.xcframework/ios-arm64"
TMP="$(mktemp -d)"
TARGET="arm64-apple-ios15.0"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "▸ Compiling OphanimCore (Swift, whole-module) for iOS…"
SWIFT_SRCS=$(ls "$CORE"/*.swift)
# -D OPHANIM_SIBLING renames the @objc entry class to OPAgentBootstrap so it doesn't collide with
# the embedded Galgal runtime's OPBootstrap class when both are loaded in the same process.
swiftc -sdk "$SDK" -target "$TARGET" -wmo -parse-as-library -D OPHANIM_SIBLING \
  -import-objc-header "$CORE/OPRing.h" \
  -module-name OphanimAgent -emit-object $SWIFT_SRCS -o "$TMP/ophanimcore.o"

echo "▸ Compiling ObjC sources…"
# -D OPHANIM_SIBLING activates agent-only interposes (e.g. OPHooksFSRaw.m's raw-POSIX filesystem
# capture) that the embedded Galgal target must NOT compile. Mirrors the swiftc flag above.
OBJC_OBJS=()
for m in "$CORE"/*.m; do
  o="$TMP/$(basename "${m%.m}").o"
  clang -c -fobjc-arc -D OPHANIM_SIBLING -isysroot "$SDK" -target "$TARGET" "$m" -o "$o"
  OBJC_OBJS+=("$o")
done

echo "▸ Compiling C / asm sources (inline-hook engine)…"
for c in "$CORE"/*.c; do
  [ -e "$c" ] || continue
  o="$TMP/$(basename "${c%.c}").o"
  clang -c -D OPHANIM_SIBLING -isysroot "$SDK" -target "$TARGET" "$c" -o "$o"
  OBJC_OBJS+=("$o")
done
for s in "$CORE"/*.s; do
  [ -e "$s" ] || continue
  o="$TMP/$(basename "${s%.s}").o"
  clang -c -isysroot "$SDK" -target "$TARGET" "$s" -o "$o"
  OBJC_OBJS+=("$o")
done

echo "▸ Linking dylib (Swift runtime + frameworks)…"
swiftc -emit-library -sdk "$SDK" -target "$TARGET" \
  "$TMP/ophanimcore.o" "${OBJC_OBJS[@]}" \
  -Xlinker -U -Xlinker _SSL_read -Xlinker -U -Xlinker _SSL_write \
  -framework Foundation -framework UIKit -framework JavaScriptCore -framework Security \
  -o "$TMP/OphanimAgent.dylib" \
  -Xlinker -install_name -Xlinker "@rpath/OphanimAgent.dylib"

echo "▸ Retagging Mach-O platform iOS → Mac Catalyst…"
# Use Apple's vtool via xcrun, NOT a bare `vtool` - a cctools-port vtool on PATH (e.g.
# Anaconda's /opt/homebrew/anaconda3/bin/vtool) segfaults on some Mach-O inputs.
xcrun vtool -set-build-version maccatalyst 14.0 26.0 -replace \
  -output "$TMP/OphanimAgent.dylib" "$TMP/OphanimAgent.dylib"

echo "▸ Ad-hoc signing + staging…"
codesign --force --sign - --timestamp=none "$TMP/OphanimAgent.dylib"
mkdir -p "$STAGE"
cp "$TMP/OphanimAgent.dylib" "$STAGE/OphanimAgent.dylib"
rm -rf "$TMP"
echo "✓ Staged → $STAGE/OphanimAgent.dylib"
