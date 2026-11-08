#!/bin/bash
# Выпуск новой версии одной командой:
#   1) поднимите CFBundleShortVersionString и CFBundleVersion в project.yml
#   2) допишите раздел ## [версия] в CHANGELOG.md
#   3) scripts/release.sh
# Скрипт соберёт DMG, подпишет его ключом обновлений, создаст релиз на GitHub
# (со списком изменений и DMG — старые версии остаются доступны) и добавит версию в appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/.*CFBundleVersion: "\(.*\)"/\1/p' project.yml)
DMG=build/Shuttle-$VERSION.dmg
# DMG для обновлений — копия на сайте: github.com доступен не везде, а сайт доступен.
URL=https://q7n3t.github.io/shuttle/dl/Shuttle-$VERSION.dmg
SPARKLE=build/Debug.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin

grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "✗ Нет раздела [$VERSION] в CHANGELOG.md"; exit 1; }
grep -q "\"$VERSION\"" docs/changelog.en.json || echo "⚠ Нет английского описания $VERSION в docs/changelog.en.json — на английском сайте будет русский текст"
if gh release view "v$VERSION" >/dev/null 2>&1; then echo "✗ Релиз v$VERSION уже есть"; exit 1; fi
[[ -z $(git status --porcelain -- Sources project.yml) ]] || { echo "✗ Есть незакоммиченные изменения в коде"; exit 1; }

scripts/make-dmg.sh

echo "▸ Подпись обновления"
SIGN=$("$SPARKLE/sign_update" "$DMG")
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGN")
LEN=$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIGN")

echo "▸ Релиз на GitHub"
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## \\["v"\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md | sed '/^\s*$/d')
git add CHANGELOG.md && git commit -q -m "update changelog" || true
git push -q
gh release create "v$VERSION" "$DMG" --title "Shuttle $VERSION" --notes "$NOTES

---
**Установка:** откройте DMG и перетащите Shuttle в «Программы».
Уже стоит Shuttle 0.3.0 или новее — обновление придёт само."

echo "▸ appcast.xml"
python3 scripts/appcast.py "$VERSION" "$BUILD" "$URL" "$SIG" "$LEN"
echo "▸ Сайт: копия DMG для обновлений (до того, как appcast позовёт на новую версию)"
gh workflow run pages.yml --ref main >/dev/null
sleep 8
gh run watch "$(gh run list --workflow pages.yml -L1 --json databaseId -q '.[0].databaseId')" --exit-status >/dev/null
for i in $(seq 1 30); do
  [[ $(curl -s -o /dev/null -w "%{http_code}" -I "$URL") == 200 ]] && break
  sleep 10
done
git add appcast.xml && git commit -q -m "update appcast" && git push -q

echo "✓ Shuttle $VERSION выпущен: https://github.com/Q7N3T/shuttle/releases/tag/v$VERSION"
