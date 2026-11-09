#!/usr/bin/env python3
"""Adds a version to appcast.xml. Release notes come from both changelogs.

appcast.py <version> <build> <url> <edSignature> <length>

The description keeps the Russian list as <li> items (that is what Wirrow 0.5.2
and older read) and adds the English list as <p> items inside
<div data-lang="en">, which newer versions pick when the app is in English.
"""
import html
import re
import sys
from email.utils import formatdate
from pathlib import Path

version, build, url, sig, length = sys.argv[1:6]
root = Path(__file__).resolve().parent.parent


def changelog_items(name, v):
    text = (root / name).read_text(encoding="utf-8")
    m = re.search(rf"^## \[{re.escape(v)}\].*?$(.*?)(?=^## \[|\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"No [{v}] section in {name}")
    return [l[2:].strip() for l in m.group(1).splitlines() if l.startswith("- ")]


ru = changelog_items("CHANGELOG.ru.md", version)
en = changelog_items("CHANGELOG.md", version)
notes = ("<ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in ru) + "</ul>"
         + '<div data-lang="en">' + "".join(f"<p>{html.escape(i)}</p>" for i in en) + "</div>")
item = f"""    <item>
      <title>Wirrow {version}</title>
      <pubDate>{formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/Q7N3T/wirrow/releases/tag/v{version}</link>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" sparkle:edSignature="{sig}" length="{length}" type="application/octet-stream"/>
    </item>
"""
path = root / "appcast.xml"
xml = path.read_text(encoding="utf-8")
# Releasing the same version again replaces its old entry.
xml = re.sub(rf"\s*<item>(?:(?!</item>).)*<sparkle:shortVersionString>{re.escape(version)}</sparkle:shortVersionString>.*?</item>\n?",
             "\n", xml, flags=re.S)
anchor = re.search(r"    <language>\w+</language>\n", xml).group(0)
xml = xml.replace(anchor, anchor + item, 1)
path.write_text(xml, encoding="utf-8")
print(f"appcast: {version} ({len(en)} items)")
