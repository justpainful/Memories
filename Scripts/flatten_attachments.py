#!/usr/bin/env python3
"""Turn xcresulttool's attachment export into a clean folder of named screenshots.

The export mixes PNGs, logs and extension-less blobs, with names like
`01-home_0_9A8FA12A-...png`. Uploading that folder wholesale is fragile, so this copies
just the images out under the name the test gave them.

    python3 Scripts/flatten_attachments.py Attachments Screenshots
"""

from __future__ import annotations

import os
import re
import shutil
import sys

# `01-home_0_<uuid>.png` -> `01-home`
NAMED = re.compile(r"^(.*?)_\d+_[0-9A-Fa-f-]{36}\.png$")


def main() -> int:
    source = sys.argv[1] if len(sys.argv) > 1 else "Attachments"
    destination = sys.argv[2] if len(sys.argv) > 2 else "Screenshots"
    os.makedirs(destination, exist_ok=True)

    if not os.path.isdir(source):
        print(f"{source} is not a directory; nothing to flatten")
        return 0

    copied = 0
    fallback = 0
    for directory, _, files in os.walk(source):
        for name in sorted(files):
            if not name.lower().endswith(".png"):
                continue
            path = os.path.join(directory, name)
            match = NAMED.match(name)
            if match:
                target = os.path.join(destination, f"{match.group(1)}.png")
                copied += 1
            else:
                # Unnamed attachment — still worth keeping, just less useful.
                target = os.path.join(destination, f"unnamed-{fallback:02d}.png")
                fallback += 1
            shutil.copyfile(path, target)

    print(f"copied {copied} named and {fallback} unnamed screenshots into {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
