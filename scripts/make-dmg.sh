#!/bin/bash
# Builds Release (arm64 + x86_64) and packs it into build/Wirrow-<version>.dmg
# with a styled window: background, arrow, icons in place.
# Build folders are named *.noindex so Spotlight and Launchpad ignore them.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
IDENTITY="Apple Development"
OUT=build/Wirrow-$VERSION.dmg
DD=build/Release.noindex
ASSETS=build/dmg-assets.noindex
VENV=build/venv.noindex

echo "▸ Libraries"
scripts/build-deps.sh

echo "▸ Release build $VERSION"
xcodegen generate -q
xcodebuild -project Wirrow.xcodeproj -scheme Wirrow -configuration Release \
  -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
APP=$DD/Build/Products/Release/Wirrow.app

echo "▸ Checks"
if otool -L "$APP/Contents/MacOS/Wirrow" | grep -q /opt/homebrew; then
  echo "✗ The app links against Homebrew"; exit 1
fi
lipo -info "$APP/Contents/MacOS/Wirrow"
codesign --verify --deep --strict "$APP"
vtool -show-build "$APP/Contents/MacOS/Wirrow" | grep -m1 minos

echo "▸ Window background"
# The Debug build draws the background (--dmg-background mode).
xcodebuild -project Wirrow.xcodeproj -scheme Wirrow -configuration Debug \
  -derivedDataPath build/Debug.noindex build -quiet
DBG=build/Debug.noindex/Build/Products/Debug/Wirrow.app/Contents/MacOS/Wirrow
mkdir -p "$ASSETS"
"$DBG" --dmg-background "$ASSETS/bg.png" 1
"$DBG" --dmg-background "$ASSETS/bg@2x.png" 2

echo "▸ DMG"
if [[ ! -x $VENV/bin/dmgbuild ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q dmgbuild
fi
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" -D assets="$ASSETS" \
  "Wirrow $VERSION" "$OUT" >/dev/null
codesign --sign "$IDENTITY" "$OUT"

# Unregister build products so Launchpad only shows the installed Wirrow.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$PWD/$APP" 2>/dev/null || true
"$LSR" -u "$PWD/build/Debug.noindex/Build/Products/Debug/Wirrow.app" 2>/dev/null || true

echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
