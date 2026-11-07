#!/bin/bash
# Собирает Release (arm64 + x86_64) и упаковывает в build/Shuttle-<версия>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
IDENTITY="Apple Development"
OUT=build/Shuttle-$VERSION.dmg

echo "▸ Библиотеки"
scripts/build-deps.sh

echo "▸ Сборка Release $VERSION"
xcodegen generate -q
xcodebuild -project Shuttle.xcodeproj -scheme Shuttle -configuration Release \
  -derivedDataPath build/Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
APP=build/Release/Build/Products/Release/Shuttle.app

echo "▸ Проверка"
if otool -L "$APP/Contents/MacOS/Shuttle" | grep -q /opt/homebrew; then
  echo "✗ Приложение ссылается на Homebrew"; exit 1
fi
lipo -info "$APP/Contents/MacOS/Shuttle"
codesign --verify --deep --strict "$APP"
vtool -show-build "$APP/Contents/MacOS/Shuttle" | grep -m1 minos

echo "▸ DMG"
STAGE=build/dmg
rm -rf "$STAGE" "$OUT"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Иконка тома — как у приложения.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
TMP=build/Shuttle-tmp.dmg; rm -f "$TMP"
hdiutil create -volname "Shuttle $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMP" -quiet
MNT=$(hdiutil attach "$TMP" -nobrowse -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
SetFile -a C "$MNT" 2>/dev/null || true
hdiutil detach "$MNT" -quiet
hdiutil convert "$TMP" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -f "$TMP"
codesign --sign "$IDENTITY" "$OUT"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
