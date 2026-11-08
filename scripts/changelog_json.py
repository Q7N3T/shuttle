#!/usr/bin/env python3
"""Builds the site's release notes from the changelogs.

CHANGELOG.md (English) -> docs/changelog.en.json
CHANGELOG.ru.md (Russian) -> docs/changelog.ru.json

Each file maps a version to its list of changes: {"0.5.2": ["…", "…"]}.
"""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent


def sections(path):
    text = path.read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r"^## \[([^\]]+)\].*?$(.*?)(?=^## \[|\Z)", text, re.S | re.M):
        out[m.group(1)] = [l[2:].strip() for l in m.group(2).splitlines() if l.startswith("- ")]
    return out


def write(data, path):
    # One version per block, items on their own lines: easy to read in diffs.
    lines = ["{"]
    keys = list(data)
    for i, v in enumerate(keys):
        items = (",\n" + " " * (len(v) + 7)).join(json.dumps(x, ensure_ascii=False) for x in data[v])
        lines.append(f'  "{v}": [{items}]' + ("," if i < len(keys) - 1 else ""))
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    write(sections(root / "CHANGELOG.md"), root / "docs" / "changelog.en.json")
    write(sections(root / "CHANGELOG.ru.md"), root / "docs" / "changelog.ru.json")
    print("site notes: docs/changelog.en.json, docs/changelog.ru.json")
