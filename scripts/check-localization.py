#!/usr/bin/env python3
"""Audit stable AppKit localization keys and complete English fallback resources."""
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
catalog = root / "Sources/JortAppKit/Resources/en.lproj/Localizable.strings"
values = {}
for line in catalog.read_text().splitlines():
    match = re.fullmatch(r'(".*") = (".*");', line)
    if match:
        key, value = (json.loads(part) for part in match.groups())
        if key in values:
            raise SystemExit(f"Duplicate localization key: {key}")
        values[key] = value
used = set()
for source in (root / "Sources/JortAppKit").glob("*.swift"):
    for match in re.finditer(
        r'LocalizedCopy\.(?:text|format)\(\s*"([^"]+)"\s*,\s*fallback:\s*"((?:[^"\\]|\\.)*)"',
        source.read_text(),
    ):
        key, fallback = match.groups()
        used.add(key)
        if values.get(key) != json.loads('"' + fallback + '"'):
            raise SystemExit(f"{source.name}: missing/mismatched English resource for {key}")
print(f"Validated {len(used)} localized AppKit keys and English fallbacks.")

# Newly extracted presentation owners must not introduce untracked static copy.
for name in ["InvocationViews", "InvocationOverlayCoordinator", "LineRuler", "EditorShell", "EditorStorageProjection", "ToolInvocationPresentation", "LinePresentationLayout"]:
    source = root / "Sources/JortAppKit" / (name + ".swift")
    for match in re.finditer(r'(?:setAccessibilityLabel|labelWithString|wrappingLabelWithString)\(\s*"([^"\n]*)"', source.read_text()):
        literal = match.group(1)
        if re.search(r"[A-Za-z]", literal):
            raise SystemExit(f"{source.name}: raw UI copy must use LocalizedCopy: {literal}")
