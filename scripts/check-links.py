#!/usr/bin/env python3
"""Check that every internal link in the documentation resolves.

Relative file links must point at a file that exists, and `#anchor` fragments
must match a heading in the target document. External links are not checked —
that would make the build depend on the network.

Run from the repository root:

    python3 scripts/check-links.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC_GLOB_DIRS = ("docs",)
TOP_LEVEL = ("README.md", "CONTRIBUTING.md", "NOTICE")

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$")


def slug(text: str) -> str:
    """Approximate the anchor GitHub generates for a heading."""
    text = text.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s+", "-", text)


def collect_files() -> list[str]:
    files = list(TOP_LEVEL)
    for directory in DOC_GLOB_DIRS:
        path = os.path.join(ROOT, directory)
        if os.path.isdir(path):
            files.extend(
                os.path.join(directory, name)
                for name in sorted(os.listdir(path))
                if name.endswith(".md")
            )
    return [f for f in files if os.path.exists(os.path.join(ROOT, f))]


def headings_of(rel_path: str) -> set[str]:
    found: set[str] = set()
    with open(os.path.join(ROOT, rel_path), encoding="utf-8") as handle:
        in_code_block = False
        for line in handle:
            if line.startswith("```"):
                in_code_block = not in_code_block
                continue
            if in_code_block:
                continue
            match = HEADING_RE.match(line)
            if match:
                found.add(slug(match.group(1)))
    return found


def main() -> int:
    files = collect_files()
    anchors = {f: headings_of(f) for f in files}

    errors: list[str] = []
    checked = 0

    for rel_path in files:
        base = os.path.dirname(rel_path)
        with open(os.path.join(ROOT, rel_path), encoding="utf-8") as handle:
            for lineno, line in enumerate(handle, 1):
                for target in LINK_RE.findall(line):
                    if target.startswith(("http://", "https://", "mailto:")):
                        continue
                    checked += 1
                    path, _, fragment = target.partition("#")
                    if path:
                        resolved = os.path.normpath(os.path.join(base, path))
                        if not os.path.exists(os.path.join(ROOT, resolved)):
                            errors.append(f"{rel_path}:{lineno} missing file: {target}")
                            continue
                        target_file = resolved
                    else:
                        target_file = rel_path
                    if fragment:
                        if fragment not in anchors.get(target_file, set()):
                            errors.append(
                                f"{rel_path}:{lineno} missing anchor: {target}"
                            )

    print(f"checked {checked} internal link(s) across {len(files)} file(s)")
    if errors:
        print("\nbroken links:")
        for error in errors:
            print(f"  {error}")
        return 1
    print("all internal links resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
