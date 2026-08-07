#!/usr/bin/env python3
"""Generate a synthetic photo library for the simulator used by the UI Smoke workflow.

`xcrun simctl addmedia` reads EXIF DateTimeOriginal, so writing real dates here is what
lets On This Day, the through-the-years strips and the calendar have anything to show.
The set is shaped to exercise the analysis pipeline rather than to look pretty:

  * spread across ~6 years so year-over-year memories exist
  * an anniversary cluster on today's date in several past years
  * one dense evening burst so event clustering has a real event to find
  * a run of near-identical frames so similarity clustering has duplicates to collapse

    python Scripts/make_seed_photos.py --out /tmp/seed --count 84
"""

from __future__ import annotations

import argparse
import datetime as dt
import math
import os
import random

import piexif
from PIL import Image, ImageDraw

W, H = 1080, 1440

PALETTES = [
    ((0x2E, 0x3A, 0x4B), (0xC9, 0x7B, 0x4A)),
    ((0x14, 0x2A, 0x22), (0xE0, 0xC8, 0x74)),
    ((0x40, 0x1C, 0x22), (0xE8, 0x7A, 0x5C)),
    ((0x1B, 0x24, 0x38), (0x8F, 0xB4, 0xC9)),
    ((0x33, 0x2A, 0x18), (0xF0, 0xB8, 0x60)),
    ((0x22, 0x18, 0x2C), (0xB9, 0x8B, 0xD0)),
    ((0x10, 0x30, 0x30), (0x7F, 0xD4, 0xC1)),
]


def frame(seed: int, drift: float = 0.0) -> Image.Image:
    """A deterministic abstract 'photo'. drift > 0 nudges it slightly, for near-duplicates."""
    rnd = random.Random(seed)
    top, bottom = PALETTES[seed % len(PALETTES)]

    strip = Image.new("RGB", (1, 256))
    px = strip.load()
    for i in range(256):
        t = i / 255
        px[0, i] = (round(top[0] + (bottom[0] - top[0]) * t),
                    round(top[1] + (bottom[1] - top[1]) * t),
                    round(top[2] + (bottom[2] - top[2]) * t))
    img = strip.resize((W, H), Image.BILINEAR)
    d = ImageDraw.Draw(img, "RGBA")

    for i in range(5):
        r = int(W * (0.18 + 0.12 * rnd.random()))
        cx = int(W * (0.15 + 0.7 * rnd.random()) + drift * W * 0.02)
        cy = int(H * (0.15 + 0.7 * rnd.random()) + drift * H * 0.02)
        tint = (255, 255, 255, 26) if i % 2 else (0, 0, 0, 34)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=tint)

    horizon = int(H * (0.58 + 0.1 * rnd.random()))
    d.rectangle([0, horizon, W, H], fill=(0, 0, 0, 70))
    sun_r = int(W * 0.09)
    sx = int(W * (0.25 + 0.5 * rnd.random()) + drift * W * 0.015)
    d.ellipse([sx - sun_r, horizon - int(H * 0.16) - sun_r,
               sx + sun_r, horizon - int(H * 0.16) + sun_r],
              fill=(255, 244, 214, 210))
    return img


def save(img: Image.Image, path: str, when: dt.datetime) -> None:
    stamp = when.strftime("%Y:%m:%d %H:%M:%S")
    exif = {
        "0th": {piexif.ImageIFD.Make: b"Memories", piexif.ImageIFD.Model: b"Seed",
                piexif.ImageIFD.DateTime: stamp.encode()},
        "Exif": {piexif.ExifIFD.DateTimeOriginal: stamp.encode(),
                 piexif.ExifIFD.DateTimeDigitized: stamp.encode()},
        "GPS": {}, "1st": {}, "thumbnail": None,
    }
    img.save(path, "JPEG", quality=88, exif=piexif.dump(exif))
    # `simctl addmedia` prefers EXIF DateTimeOriginal but falls back to the file's own
    # modification time, so set both. Without a date the whole library imports as "now"
    # and every anniversary memory comes out empty.
    stamp_seconds = when.timestamp()
    os.utime(path, (stamp_seconds, stamp_seconds))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=84)
    ap.add_argument("--today", default=None, help="YYYY-MM-DD, defaults to now")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    rnd = random.Random(20260807)
    plan: list[tuple[dt.datetime, int, float]] = []

    # anniversaries: same calendar day, 1..5 years back
    for years in (1, 2, 3, 5):
        try:
            day = today.replace(year=today.year - years)
        except ValueError:                      # 29 Feb
            day = today.replace(year=today.year - years, day=28)
        for k in range(3):
            plan.append((dt.datetime.combine(day, dt.time(11 + k * 3, 20 + k * 7)),
                         100 + years * 10 + k, 0.0))

    # one dense evening, two years ago: an event worth clustering
    evening = dt.datetime.combine(today.replace(year=today.year - 2), dt.time(20, 2))
    for k in range(18):
        plan.append((evening + dt.timedelta(minutes=4 * k + rnd.randint(0, 3)), 300 + k, 0.0))

    # five near-identical frames last year: duplicates to collapse
    burst = dt.datetime.combine(today.replace(year=today.year - 1), dt.time(16, 41))
    for k in range(5):
        plan.append((burst + dt.timedelta(seconds=6 * k), 777, 0.35 * k))

    # the rest scattered over six years so the timeline and calendar fill in
    while len(plan) < args.count:
        back = rnd.randint(1, 6 * 365)
        when = dt.datetime.combine(today - dt.timedelta(days=back),
                                   dt.time(rnd.randint(7, 22), rnd.randint(0, 59)))
        plan.append((when, rnd.randint(0, 9999), 0.0))

    plan.sort(key=lambda p: p[0])
    for i, (when, seed, drift) in enumerate(plan[:args.count]):
        path = os.path.join(args.out, f"seed_{i:03d}_{when:%Y%m%d_%H%M%S}.jpg")
        save(frame(seed, drift), path, when)

    print(f"wrote {min(len(plan), args.count)} seed photos to {args.out}")


if __name__ == "__main__":
    main()
