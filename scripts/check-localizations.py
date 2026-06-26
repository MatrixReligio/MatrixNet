#!/usr/bin/env python3
"""Fail if any String Catalog key is missing a translation for a supported
language. Run in CI so a newly-added UI string can't ship untranslated.

Usage: python3 scripts/check-localizations.py
"""
import json
import sys
from pathlib import Path

REQUIRED = {"zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"}
# Brand name and bare identifiers intentionally share the English source.
SKIP_KEYS = {"", "MatrixNet", "PID"}
CATALOGS = [
    "App/Resources/Localizable.xcstrings",
    "Widget/Resources/Localizable.xcstrings",
]


def check(path: str) -> list[str]:
    doc = json.loads(Path(path).read_text())
    problems = []
    for key, entry in doc.get("strings", {}).items():
        if key in SKIP_KEYS:
            continue
        locs = entry.get("localizations", {})
        for lang in sorted(REQUIRED):
            unit = locs.get(lang, {}).get("stringUnit", {})
            if unit.get("state") != "translated" or not unit.get("value"):
                problems.append(f"{path}: '{key}' missing/untranslated for {lang}")
    return problems


def main() -> int:
    all_problems = []
    for catalog in CATALOGS:
        if not Path(catalog).exists():
            print(f"warning: {catalog} not found", file=sys.stderr)
            continue
        all_problems.extend(check(catalog))
    if all_problems:
        print("Missing translations:\n" + "\n".join(all_problems), file=sys.stderr)
        return 1
    print(f"All catalog keys translated into: {', '.join(sorted(REQUIRED))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
