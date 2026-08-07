#!/usr/bin/env python3
"""Turn xcresulttool's attachment export into a clean folder of named screenshots.

    python3 Scripts/flatten_attachments.py Attachments Screenshots

`xcresulttool export attachments` writes the files under opaque names and puts the names the
test gave them in a `manifest.json` beside them. Reading that manifest is the whole job.

This script used to try to recover the name from the filename instead, on the assumption that
the export was still writing `01-home_0_<uuid>.png`. It is not — the files come out as bare
identifiers — so every screenshot landed as `unnamed-07.png` and the artifact became thirteen
anonymous PNGs. That is not a cosmetic problem: the run it hid was one where the tour got
stuck in the photo viewer and photographed it eight times, and with names that would have been
obvious at a glance instead of something to reconstruct from pixels.

The filename fallback is kept for anything the manifest does not mention.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys

# Legacy export names carried a UUID and sometimes an index: `01-home_0_<uuid>.png`.
UUID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
TRAILING_INDEX = re.compile(r"_\d+$")

# The manifest has changed shape between Xcode versions, so rather than hard-code a path into
# it, walk it and take any object that names an exported file.
FILE_KEYS = ("exportedFileName", "exported_file_name", "fileName", "filename")
NAME_KEYS = ("suggestedHumanReadableName", "suggested_human_readable_name", "name")


def names_from_manifest(source: str) -> dict[str, str]:
    """Map exported filename -> the name the test gave the attachment."""
    path = os.path.join(source, "manifest.json")
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"could not read {path}: {error}")
        return {}

    found: dict[str, str] = {}

    def walk(node: object) -> None:
        if isinstance(node, list):
            for item in node:
                walk(item)
            return
        if not isinstance(node, dict):
            return

        filename = next((node[k] for k in FILE_KEYS if isinstance(node.get(k), str)), None)
        label = next((node[k] for k in NAME_KEYS if isinstance(node.get(k), str)), None)
        if filename and label:
            found[filename] = label

        for value in node.values():
            walk(value)

    walk(manifest)
    return found


def sanitize(label: str) -> str:
    """A screenshot name becomes a filename, so it may not carry separators."""
    stem = os.path.splitext(label)[0]
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip("-_.")
    return cleaned


def name_from_filename(filename: str) -> str:
    stem = os.path.splitext(filename)[0]
    return TRAILING_INDEX.sub("", UUID.sub("", stem).strip("_- "))


def main() -> int:
    source = sys.argv[1] if len(sys.argv) > 1 else "Attachments"
    destination = sys.argv[2] if len(sys.argv) > 2 else "Screenshots"
    os.makedirs(destination, exist_ok=True)

    if not os.path.isdir(source):
        print(f"{source} is not a directory; nothing to flatten")
        return 0

    manifest = names_from_manifest(source)
    print(f"manifest named {len(manifest)} attachments")

    named = 0
    unnamed = 0
    used: set[str] = set()

    for directory, _, files in os.walk(source):
        for filename in sorted(files):
            if not filename.lower().endswith(".png"):
                continue

            label = sanitize(manifest.get(filename) or name_from_filename(filename))
            if label:
                named += 1
            else:
                label = f"unnamed-{unnamed:02d}"
                unnamed += 1

            # Two captures may legitimately share a name; keep both rather than overwrite,
            # because a silently dropped screenshot is exactly the kind of gap this lane exists
            # to close.
            target = label
            suffix = 2
            while target in used:
                target = f"{label}-{suffix}"
                suffix += 1
            used.add(target)

            shutil.copyfile(os.path.join(directory, filename),
                            os.path.join(destination, f"{target}.png"))

    print(f"copied {named} named and {unnamed} unnamed screenshots into {destination}")
    if named == 0 and unnamed > 0:
        # Loud, because this is recoverable evidence being thrown away rather than a failure.
        print("::warning::No screenshot kept its name; check manifest.json in the export")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
