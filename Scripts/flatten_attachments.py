#!/usr/bin/env python3
"""Flatten xcresulttool's attachment export into readable screenshot files.

`xcresulttool export attachments` writes each test's attachments into per-test folders with
opaque filenames plus a manifest.json that carries the name the test actually gave them.
This rewrites them as `<attachment name>.png` at the top level so the CI artifact can be
skimmed instead of decoded.

    python3 Scripts/flatten_attachments.py Screenshots
"""

from __future__ import annotations

import json
import os
import shutil
import sys


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "Screenshots"
    if not os.path.isdir(root):
        print(f"{root} is not a directory")
        return 0

    moved = 0
    for directory, _, files in os.walk(root):
        if "manifest.json" not in files:
            continue
        with open(os.path.join(directory, "manifest.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)

        # The manifest shape has changed across Xcode versions; handle both a top-level list
        # and a dict of test identifiers to attachment lists.
        entries = manifest if isinstance(manifest, list) else manifest.values()
        for entry in entries:
            attachments = entry.get("attachments", []) if isinstance(entry, dict) else []
            for attachment in attachments:
                exported = attachment.get("exportedFileName")
                name = attachment.get("suggestedHumanReadableName") or attachment.get("name")
                if not exported or not name:
                    continue
                source = os.path.join(directory, exported)
                if not os.path.exists(source):
                    continue
                stem = os.path.splitext(name)[0]
                target = os.path.join(root, f"{stem}.png")
                shutil.copyfile(source, target)
                moved += 1

    print(f"flattened {moved} attachments into {root}")

    # Anything the manifest did not describe is still worth keeping; surface it by copying
    # every png found deeper in the tree up to the top level under a generic name.
    if moved == 0:
        index = 0
        for directory, _, files in os.walk(root):
            if os.path.abspath(directory) == os.path.abspath(root):
                continue
            for name in sorted(files):
                if name.lower().endswith(".png"):
                    shutil.copyfile(os.path.join(directory, name),
                                    os.path.join(root, f"attachment-{index:02d}.png"))
                    index += 1
        print(f"no manifest entries; copied {index} raw png attachments")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
