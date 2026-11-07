#!/usr/bin/env python3
"""Добавляет версию в appcast.xml. Пункты изменений берёт из CHANGELOG.md.

appcast.py <version> <build> <url> <edSignature> <length>
"""
import html, re, sys
from email.utils import formatdate
from pathlib import Path

version, build, url, sig, length = sys.argv[1:6]
root = Path(__file__).resolve().parent.parent


def changelog_items(v):
    text = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    m = re.search(rf"^## \[{re.escape(v)}\].*?$(.*?)(?=^## \[|\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"В CHANGELOG.md нет раздела [{v}]")
    return [l[2:].strip() for l in m.group(1).splitlines() if l.startswith("- ")]


items = changelog_items(version)
notes = "<ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in items) + "</ul>"
item = f"""    <item>
      <title>Shuttle {version}</title>
      <pubDate>{formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/Q7N3T/shuttle/releases/tag/v{version}</link>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" sparkle:edSignature="{sig}" length="{length}" type="application/octet-stream"/>
    </item>
"""
path = root / "appcast.xml"
xml = path.read_text(encoding="utf-8")
# Повторный выпуск той же версии заменяет старую запись.
xml = re.sub(rf"\s*<item>(?:(?!</item>).)*<sparkle:shortVersionString>{re.escape(version)}</sparkle:shortVersionString>.*?</item>\n?",
             "\n", xml, flags=re.S)
xml = xml.replace("    <language>ru</language>\n", "    <language>ru</language>\n" + item, 1)
path.write_text(xml, encoding="utf-8")
print(f"appcast: {version} ({len(items)} пунктов)")
