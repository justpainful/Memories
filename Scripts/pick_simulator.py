#!/usr/bin/env python3
"""Print the UDID of the newest available simulator of a given family, on the newest iOS runtime.

Runner images change their device and runtime line-up without warning, so the UI Smoke
workflow discovers a simulator instead of hard-coding one.

    xcrun simctl list devices available --json | python3 Scripts/pick_simulator.py
    xcrun simctl list devices available --json | python3 Scripts/pick_simulator.py iPad

The family argument exists because the app is no longer iPhone-only. A build that declares
iPad support and is never once launched on an iPad has not been tested on an iPad; it has been
assumed to work on one, which is the failure mode this whole lane exists to catch.
"""

from __future__ import annotations

import json
import re
import sys


def runtime_key(identifier: str) -> tuple:
    return tuple(int(n) for n in re.findall(r"\d+", identifier)) or (0,)


def device_key(name: str) -> tuple:
    """Rank by model number, then prefer the bigger screen of a generation."""
    numbers = tuple(int(n) for n in re.findall(r"\d+", name)) or (0,)
    rank = 3 if "Pro Max" in name else 2 if "Pro" in name else 1 if "Plus" in name else 0
    return (numbers, rank)


def main() -> int:
    family = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
    devices = json.load(sys.stdin)["devices"]
    for runtime in sorted(devices, key=runtime_key, reverse=True):
        if "iOS" not in runtime:
            continue
        matches = [d for d in devices[runtime] if d.get("isAvailable") and family in d["name"]]
        if not matches:
            continue
        chosen = max(matches, key=lambda d: device_key(d["name"]))
        print(chosen["udid"])
        print(f"{chosen['name']} on {runtime}", file=sys.stderr)
        return 0

    print(f"no available {family} simulator found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
