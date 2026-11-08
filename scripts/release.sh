#!/bin/bash
# Ship a new version with one command:
#   1) bump CFBundleShortVersionString and CFBundleVersion in project.yml
#   2) add a ## [version] section to CHANGELOG.md (English) and CHANGELOG.ru.md (Russian)
#   3) scripts/release.sh
# The script builds the DMG, signs it with the update key, creates a GitHub release
# (with release notes and the DMG — older versions stay downloadable), mirrors the DMG
# on the site and adds the version to appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/.*CFBundleVersion: "\(.*\)"/\1/p' project.yml)
DMG=build/Shuttle-$VERSION.dmg
# Updates download the DMG from the site mirror: github.com is blocked in some networks, the site is not.
URL=https://q7n3t.github.io/shuttle/dl/Shuttle-$VERSION.dmg
SPARKLE=build/Debug.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin

grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "✗ No [$VERSION] section in CHANGELOG.md"; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.ru.md || { echo "✗ No [$VERSION] section in CHANGELOG.ru.md"; exit 1; }
if gh release view "v$VERSION" >/dev/null 2>&1; then echo "✗ Release v$VERSION already exists"; exit 1; fi
[[ -z $(git status --porcelain -- Sources project.yml) ]] || { echo "✗ Uncommitted changes in the code"; exit 1; }

scripts/make-dmg.sh

echo "▸ Signing the update"
SIGN=$("$SPARKLE/sign_update" "$DMG")
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGN")
LEN=$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIGN")

echo "▸ Changelogs and site notes"
python3 scripts/changelog_json.py
git add CHANGELOG.md CHANGELOG.ru.md docs/changelog.en.json docs/changelog.ru.json
git commit -q -m "update changelog" || true
git push -q

echo "▸ GitHub release"
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## \\["v"\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md | sed '/^\s*$/d')
gh release create "v$VERSION" "$DMG" --title "Shuttle $VERSION" --notes "$NOTES

---
**Install:** open the DMG and drag Shuttle to Applications.
Already running Shuttle 0.3.0 or later? The update arrives by itself."

echo "▸ appcast.xml"
python3 scripts/appcast.py "$VERSION" "$BUILD" "$URL" "$SIG" "$LEN"
echo "▸ Site: DMG mirror for updates (before the appcast points to the new version)"
gh workflow run pages.yml --ref main >/dev/null
sleep 8
gh run watch "$(gh run list --workflow pages.yml -L1 --json databaseId -q '.[0].databaseId')" --exit-status >/dev/null
for i in $(seq 1 30); do
  [[ $(curl -s -o /dev/null -w "%{http_code}" -I "$URL") == 200 ]] && break
  sleep 10
done
git add appcast.xml && git commit -q -m "update appcast" && git push -q

echo "✓ Shuttle $VERSION released: https://github.com/Q7N3T/shuttle/releases/tag/v$VERSION"
