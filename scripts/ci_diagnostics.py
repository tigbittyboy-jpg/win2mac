#!/usr/bin/env python3
"""Retain compiler/test evidence rather than burying it in long Xcode commands."""
import re
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(errors="replace").splitlines()
selected = set(range(max(0, len(lines) - 40), len(lines)))
for i, line in enumerate(lines):
    if re.search(r"error:|fatal error|Testing failed|Test Case .*failed|Executed .*tests", line, re.I):
        selected.update(range(max(0, i - 1), min(len(lines), i + 4)))
for i in sorted(selected)[-200:]:
    print(lines[i][:1600])
