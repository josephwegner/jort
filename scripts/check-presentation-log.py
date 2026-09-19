#!/usr/bin/env python3
"""Strict native warning gate; never treats a passing mutation test as a waiver."""
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
warnings = [line for line in text.splitlines() if "Invalid attempt to open a new transaction during CA commit" in line]
if warnings:
    print(f"FAIL: {len(warnings)} Core Animation nested-transaction warnings")
    print("\n".join(warnings))
    raise SystemExit(1)
print("No Core Animation nested-transaction warnings.")
