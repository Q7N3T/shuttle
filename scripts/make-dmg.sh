#!/bin/bash
# Builds Release (arm64 + x86_64) and packs it into build/Shuttle-<version>.dmg
# with a styled window: background, arrow, icons in place.
# Build folders are named *.noindex so Spotlight and Launchpad ignore them.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
IDENTITY="Apple Development"
OUT=build/Shuttle-$VERSION.dmg
DD=build/Release.noindex
ASSETS=build/dmg-assets.noindex
VENV=build/venv.noindex

echo "▸ Libraries"
scripts/build-deps.sh

echo "▸ Release build $VERSION"
xcodegen generate -q
xcodebuild -project Shuttle.xcodeproj -scheme Shuttle -configuration Release \
  -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
APP=$DD/Build/Products/Release/Shuttle.app

echo "▸ Checks"
if otool -L "$APP/Contents/MacOS/Shuttle" | grep -q /opt/homebrew; then
  echo "✗ The app links against Homebrew"; exit 1
fi
lipo -info "$APP/Contents/MacOS/Shuttle"
codesign --verify --deep --strict "$APP"
vtool -show-build "$APP/Contents/MacOS/Shuttle" | grep -m1 minos

echo "▸ Window background"
# The Debug build draws the background (--dmg-background mode).
xcodebuild -project Shuttle.xcodeproj -scheme Shuttle -configuration Debug \
  -derivedDataPath build/Debug.noindex build -quiet
DBG=build/Debug.noindex/Build/Products/Debug/Shuttle.app/Contents/MacOS/Shuttle
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
  "Shuttle $VERSION" "$OUT" >/dev/null
codesign --sign "$IDENTITY" "$OUT"

# Unregister build products so Launchpad only shows the installed Shuttle.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$PWD/$APP" 2>/dev/null || true
"$LSR" -u "$PWD/build/Debug.noindex/Build/Products/Debug/Shuttle.app" 2>/dev/null || true

echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
