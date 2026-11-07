#!/bin/bash
# Собирает Release (arm64 + x86_64) и упаковывает в build/Shuttle-<версия>.dmg
# с оформленным окном: фон, стрелка, иконки на своих местах.
# Папки сборки названы *.noindex — Spotlight и Launchpad их не видят.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
IDENTITY="Apple Development"
OUT=build/Shuttle-$VERSION.dmg
DD=build/Release.noindex
ASSETS=build/dmg-assets.noindex
VENV=build/venv.noindex

echo "▸ Библиотеки"
scripts/build-deps.sh

echo "▸ Сборка Release $VERSION"
xcodegen generate -q
xcodebuild -project Shuttle.xcodeproj -scheme Shuttle -configuration Release \
  -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
APP=$DD/Build/Products/Release/Shuttle.app

echo "▸ Проверка"
if otool -L "$APP/Contents/MacOS/Shuttle" | grep -q /opt/homebrew; then
  echo "✗ Приложение ссылается на Homebrew"; exit 1
fi
lipo -info "$APP/Contents/MacOS/Shuttle"
codesign --verify --deep --strict "$APP"
vtool -show-build "$APP/Contents/MacOS/Shuttle" | grep -m1 minos

echo "▸ Фон окна"
# Фон рисует Debug-сборка (режим --dmg-background).
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

# Убираем сборки из списка приложений системы: в Launchpad останется только установленный Shuttle.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$PWD/$APP" 2>/dev/null || true
"$LSR" -u "$PWD/build/Debug.noindex/Build/Products/Debug/Shuttle.app" 2>/dev/null || true

echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
