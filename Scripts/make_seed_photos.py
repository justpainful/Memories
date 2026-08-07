#!/usr/bin/env python3
"""Generate a synthetic photo library for the simulator used by the UI Smoke workflow.

`xcrun simctl addmedia` reads the metadata inside each file, so what is written here is what
the app gets to analyse. The set is shaped to exercise the pipeline rather than to look
pretty — every group below exists because some shipped feature has no input without it:

  * spread across ~6 years so year-over-year memories exist
  * an anniversary cluster on today's date in several past years
  * one dense evening burst so event clustering has a real event to find
  * a run of near-identical frames so similarity clustering has duplicates to collapse
  * EXIF GPS in three clusters — a home city, a second town inside the same region, and one
    far enough away that `TripFinder` (100 km from the median) can find a trip in it
  * short QuickTime clips, some carrying a container creation date that deliberately
    disagrees with the file's own timestamps, which is the only way to exercise
    `ProvenanceReader.recordingDate(of:)`
  * filenames in the shapes `ProvenanceReader.platform(forFilename:)` recognises, so the
    "Saved from…" row and the date-from-filename recovery have something to read

What this fixture cannot fake is printed at the end of every run; see `NOT_COVERED`.

    python Scripts/make_seed_photos.py --out /tmp/seed --count 60
"""

from __future__ import annotations

import argparse
import datetime as dt
import io
import os
import random
import struct
from dataclasses import dataclass, field

import piexif
from PIL import Image, ImageDraw

W, H = 1080, 1440

# Videos are deliberately tiny: `addmedia` costs seconds per asset either way, and nothing in
# the app cares what is in the frames — only that a real video track decodes.
VIDEO_SIZE = (640, 360)
VIDEO_FPS = 8
VIDEO_FRAMES = 12          # 1.5 seconds

PALETTES = [
    ((0x2E, 0x3A, 0x4B), (0xC9, 0x7B, 0x4A)),
    ((0x14, 0x2A, 0x22), (0xE0, 0xC8, 0x74)),
    ((0x40, 0x1C, 0x22), (0xE8, 0x7A, 0x5C)),
    ((0x1B, 0x24, 0x38), (0x8F, 0xB4, 0xC9)),
    ((0x33, 0x2A, 0x18), (0xF0, 0xB8, 0x60)),
    ((0x22, 0x18, 0x2C), (0xB9, 0x8B, 0xD0)),
    ((0x10, 0x30, 0x30), (0x7F, 0xD4, 0xC1)),
]

# Three real places. Brighton is ~76 km from London, which is inside `TripFinder.awayRadius`
# (100 km) on purpose: it has to read as a second *place*, not as a journey. Reykjavík is
# ~1,890 km away, which is what makes the two days spent there a trip.
HOME = (51.5074, -0.1278)        # London
NEARBY = (50.8225, -0.1372)      # Brighton
FAR = (64.1466, -21.9426)        # Reykjavík

NOT_COVERED = """
Not covered by this fixture, and no amount of generated media will change it:

  * Faces / People. Vision's detector will not fire on drawn shapes, so no face observation
    is produced, no PersonRecord is created and face clustering stays empty. People screens
    are exercised only in their empty state.
  * Screenshots. PHAssetMediaSubtype.photoScreenshot is stamped by iOS when the screenshot is
    taken; `addmedia` cannot set it, so `AssetRecord.isScreenshot` is always false. A file
    *named* like a screenshot only reaches SourcePlatform.screenshot via the filename rule,
    which is a different code path and is covered.
  * Live Photos. A Live Photo needs a JPEG and a MOV sharing an Apple content identifier
    (kCGImagePropertyMakerAppleDictionary key 17 / com.apple.quicktime.content.identifier)
    imported as one asset. Writing that pairing correctly is not attempted here, so
    `isLivePhoto` is never true and the Live Photo player is never reached.
  * Reverse-geocoded place names. Coordinates are real, but `EventCluster.placeName` is only
    filled in by PlacesView's geocoding pass, so "Best of <place>" rows stay unnamed unless
    the tour visits Places.
"""


# --------------------------------------------------------------------------- stills

def frame(seed: int, drift: float = 0.0, size: tuple[int, int] = (W, H)) -> Image.Image:
    """A deterministic abstract 'photo'. drift > 0 nudges it slightly, for near-duplicates."""
    width, height = size
    rnd = random.Random(seed)
    top, bottom = PALETTES[seed % len(PALETTES)]

    strip = Image.new("RGB", (1, 256))
    px = strip.load()
    for i in range(256):
        t = i / 255
        px[0, i] = (round(top[0] + (bottom[0] - top[0]) * t),
                    round(top[1] + (bottom[1] - top[1]) * t),
                    round(top[2] + (bottom[2] - top[2]) * t))
    img = strip.resize((width, height), Image.BILINEAR)
    d = ImageDraw.Draw(img, "RGBA")

    for i in range(5):
        r = int(width * (0.18 + 0.12 * rnd.random()))
        cx = int(width * (0.15 + 0.7 * rnd.random()) + drift * width * 0.02)
        cy = int(height * (0.15 + 0.7 * rnd.random()) + drift * height * 0.02)
        tint = (255, 255, 255, 26) if i % 2 else (0, 0, 0, 34)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=tint)

    horizon = int(height * (0.58 + 0.1 * rnd.random()))
    d.rectangle([0, horizon, width, height], fill=(0, 0, 0, 70))
    sun_r = int(width * 0.09)
    sx = int(width * (0.25 + 0.5 * rnd.random()) + drift * width * 0.015)
    d.ellipse([sx - sun_r, horizon - int(height * 0.16) - sun_r,
               sx + sun_r, horizon - int(height * 0.16) + sun_r],
              fill=(255, 244, 214, 210))
    return img


def _rational(value: float) -> tuple[tuple[int, int], ...]:
    """A coordinate as EXIF wants it: degrees, minutes and seconds, each a rational."""
    degrees = int(value)
    minutes_float = (value - degrees) * 60
    minutes = int(minutes_float)
    seconds = round((minutes_float - minutes) * 60 * 10_000)
    return ((degrees, 1), (minutes, 1), (seconds, 10_000))


def gps_ifd(latitude: float, longitude: float) -> dict:
    return {
        piexif.GPSIFD.GPSVersionID: (2, 3, 0, 0),
        piexif.GPSIFD.GPSLatitudeRef: b"N" if latitude >= 0 else b"S",
        piexif.GPSIFD.GPSLatitude: _rational(abs(latitude)),
        piexif.GPSIFD.GPSLongitudeRef: b"E" if longitude >= 0 else b"W",
        piexif.GPSIFD.GPSLongitude: _rational(abs(longitude)),
        piexif.GPSIFD.GPSAltitudeRef: 0,
        piexif.GPSIFD.GPSAltitude: (24, 1),
    }


def save(img: Image.Image, path: str, when: dt.datetime,
         gps: tuple[float, float] | None = None) -> None:
    stamp = when.strftime("%Y:%m:%d %H:%M:%S")
    exif = {
        "0th": {piexif.ImageIFD.Make: b"Memories", piexif.ImageIFD.Model: b"Seed",
                piexif.ImageIFD.DateTime: stamp.encode()},
        "Exif": {piexif.ExifIFD.DateTimeOriginal: stamp.encode(),
                 piexif.ExifIFD.DateTimeDigitized: stamp.encode()},
        "GPS": gps_ifd(*gps) if gps else {}, "1st": {}, "thumbnail": None,
    }
    img.save(path, "JPEG", quality=88, exif=piexif.dump(exif))
    # `simctl addmedia` prefers EXIF DateTimeOriginal but falls back to the file's own
    # modification time, so set both. Without a date the whole library imports as "now"
    # and every anniversary memory comes out empty.
    stamp_seconds = when.timestamp()
    os.utime(path, (stamp_seconds, stamp_seconds))


# --------------------------------------------------------------------------- video

# A QuickTime file, written by hand.
#
# There is no ffmpeg on a GitHub macOS runner and `brew install ffmpeg` costs minutes on a
# lane that runs in ten, so the clips are Motion JPEG: Pillow encodes the frames and the
# handful of atoms below wrap them in a real video track. The point is not fidelity — it is
# that `AssetProvenance` has an actual container to read a date out of, and that the video
# badge, the Videos section and `MemoryVideoPlayer` see a video at all.
#
# The date written into the container is deliberately *not* the date on the file. That gap is
# the whole subject of `ProvenanceReader.recordingDate(of:)`: a clip that arrived last week
# from a holiday two years ago.

QT_EPOCH_OFFSET = 2_082_844_800     # 1904-01-01 → 1970-01-01, in seconds
TIMESCALE = 600
UNITY_MATRIX = struct.pack(">9i", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)


def _atom(kind: bytes, *parts: bytes) -> bytes:
    body = b"".join(parts)
    return struct.pack(">I", 8 + len(body)) + kind + body


def _qt_time(when: dt.datetime) -> int:
    return (int(when.timestamp()) + QT_EPOCH_OFFSET) & 0xFFFFFFFF


def _iso8601(when: dt.datetime) -> str:
    return when.astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def _text_atom(kind: bytes, text: str) -> bytes:
    """A QuickTime user-data text atom: length, language, then the string."""
    raw = text.encode("utf-8")
    return _atom(kind, struct.pack(">HH", len(raw), 0x55C4), raw)


def _mdta_metadata(items: dict[str, str]) -> bytes:
    """The `meta`/`keys`/`ilst` block Apple's own recorders use for com.apple.quicktime.*.

    Laid out to match what ffmpeg writes with `-movflags use_metadata_tags`, including the
    four zero bytes after `meta`, because that layout is known to be read back correctly.
    """
    keys = b"".join(_atom(b"mdta", key.encode()) for key in items)
    values = b""
    for index, value in enumerate(items.values(), start=1):
        data = _atom(b"data", struct.pack(">II", 1, 0), value.encode("utf-8"))
        values += _atom(struct.pack(">I", index), data)

    hdlr = _atom(b"hdlr", struct.pack(">II", 0, 0) + b"mdta" + b"\x00" * 13)
    return _atom(b"meta",
                 b"\x00\x00\x00\x00",
                 hdlr,
                 _atom(b"keys", struct.pack(">II", 0, len(items)) + keys),
                 _atom(b"ilst", values))


def _sample_description(width: int, height: int) -> bytes:
    """One Motion JPEG sample entry. Every field is fixed except the frame size."""
    name = b"Memories seed"
    compressor = bytes([len(name)]) + name + b"\x00" * (31 - len(name))
    entry = (
        b"\x00" * 6 + struct.pack(">H", 1)          # reserved, data reference index
        + struct.pack(">HHI", 0, 0, 0)              # version, revision, vendor
        + struct.pack(">II", 0, 512)                # temporal / spatial quality
        + struct.pack(">HH", width, height)
        + struct.pack(">II", 0x00480000, 0x00480000)  # 72 dpi
        + struct.pack(">IH", 0, 1)                  # data size, frames per sample
        + compressor
        + struct.pack(">Hh", 24, -1)                # depth, colour table
    )
    return _atom(b"stsd", struct.pack(">II", 0, 1) + _atom(b"jpeg", entry))


def _movie_atom(sizes: list[int], first_offset: int, width: int, height: int,
                header_time: dt.datetime, recorded: dt.datetime | None,
                metadata_style: str, location: tuple[float, float] | None) -> bytes:
    frame_duration = TIMESCALE // VIDEO_FPS
    duration = frame_duration * len(sizes)
    created = _qt_time(header_time)

    stbl = _atom(
        b"stbl",
        _sample_description(width, height),
        _atom(b"stts", struct.pack(">IIII", 0, 1, len(sizes), frame_duration)),
        _atom(b"stsc", struct.pack(">IIIII", 0, 1, 1, len(sizes), 1)),
        _atom(b"stsz", struct.pack(">III", 0, 0, len(sizes)) + b"".join(
            struct.pack(">I", size) for size in sizes)),
        _atom(b"stco", struct.pack(">III", 0, 1, first_offset)),
    )
    minf = _atom(
        b"minf",
        _atom(b"vmhd", struct.pack(">IHHHH", 1, 0, 0, 0, 0)),
        _atom(b"hdlr", struct.pack(">I", 0) + b"dhlrurl " + b"\x00" * 12
              + bytes([11]) + b"DataHandler"),
        _atom(b"dinf", _atom(b"dref", struct.pack(">II", 0, 1)
                             + _atom(b"url ", struct.pack(">I", 1)))),
        stbl,
    )
    mdia = _atom(
        b"mdia",
        _atom(b"mdhd", struct.pack(">IIIIIHH", 0, created, created, TIMESCALE, duration,
                                   0x55C4, 0)),
        _atom(b"hdlr", struct.pack(">I", 0) + b"mhlrvide" + b"\x00" * 12
              + bytes([12]) + b"VideoHandler"),
        minf,
    )
    trak = _atom(
        b"trak",
        _atom(b"tkhd", struct.pack(">IIIIII", 0x0000000F, created, created, 1, 0, duration)
              + b"\x00" * 8 + struct.pack(">HHHH", 0, 0, 0, 0) + UNITY_MATRIX
              + struct.pack(">II", width << 16, height << 16)),
        mdia,
    )

    # Two places can carry the date, and `ProvenanceReader.recordingDate(of:)` tries them in
    # this order: AVAsset's own `.creationDate`, which reads the `©day` user-data atom, then
    # the `com.apple.quicktime.creationdate` metadata key. One clip is written with the key
    # and no `©day`, so a file exists that only the second lookup can date — though
    # AVFoundation also maps that key onto the common creation-date, so it may well be the
    # first branch that answers. Either way the date is recovered from the container.
    user_data: list[bytes] = []
    if recorded and metadata_style != "mdta":
        user_data.append(_text_atom(b"\xa9day", _iso8601(recorded)))
    user_data.append(_text_atom(b"\xa9swr", "Memories seed"))
    if location:
        latitude, longitude = location
        user_data.append(_text_atom(b"\xa9xyz", f"{latitude:+08.4f}{longitude:+09.4f}/"))

    metadata: dict[str, str] = {}
    if recorded:
        metadata["com.apple.quicktime.creationdate"] = _iso8601(recorded)
    metadata["com.apple.quicktime.software"] = "Memories seed"
    if location:
        metadata["com.apple.quicktime.location.ISO6709"] = \
            f"{location[0]:+08.4f}{location[1]:+09.4f}/"
    user_data.append(_mdta_metadata(metadata))

    return _atom(
        b"moov",
        _atom(b"mvhd", struct.pack(">IIIII", 0, created, created, TIMESCALE, duration)
              + struct.pack(">IHH", 0x00010000, 0x0100, 0) + b"\x00" * 8
              + UNITY_MATRIX + b"\x00" * 24 + struct.pack(">I", 2)),
        trak,
        _atom(b"udta", *user_data),
    )


def write_clip(path: str, seed: int, saved: dt.datetime,
               recorded: dt.datetime | None = None,
               metadata_style: str = "udta",
               location: tuple[float, float] | None = None) -> None:
    """A 1.5-second Motion JPEG QuickTime clip.

    `saved` is what the file and the movie headers claim — the day it landed on the phone.
    `recorded` is what the creation-date metadata claims, and is the answer the app should
    recover. They are different on purpose.
    """
    width, height = VIDEO_SIZE
    samples: list[bytes] = []
    for index in range(VIDEO_FRAMES):
        buffer = io.BytesIO()
        frame(seed, drift=index * 0.6, size=(width, height)).save(
            buffer, "JPEG", quality=58, optimize=False)
        samples.append(buffer.getvalue())

    ftyp = _atom(b"ftyp", b"qt  " + struct.pack(">I", 0x200) + b"qt  ")
    wide = _atom(b"wide")
    payload = b"".join(samples)
    mdat = _atom(b"mdat", payload)
    first_offset = len(ftyp) + len(wide) + 8

    moov = _movie_atom([len(s) for s in samples], first_offset, width, height,
                       saved, recorded, metadata_style, location)

    with open(path, "wb") as handle:
        handle.write(ftyp + wide + mdat + moov)

    stamp = saved.timestamp()
    os.utime(path, (stamp, stamp))


# --------------------------------------------------------------------------- the plan

@dataclass
class Shot:
    when: dt.datetime
    seed: int
    drift: float = 0.0
    name: str | None = None
    gps: tuple[float, float] | None = None
    note: str = ""


@dataclass
class Clip:
    name: str
    saved: dt.datetime
    seed: int
    recorded: dt.datetime | None = None
    metadata_style: str = "udta"
    gps: tuple[float, float] | None = None
    note: str = ""


@dataclass
class Library:
    shots: list[Shot] = field(default_factory=list)
    clips: list[Clip] = field(default_factory=list)


def jitter(rnd: random.Random, centre: tuple[float, float]) -> tuple[float, float]:
    """A few hundred metres of scatter — enough to look real, far inside the 25 km at which
    `EventClustering` decides two frames were taken somewhere else."""
    return (centre[0] + rnd.uniform(-0.004, 0.004),
            centre[1] + rnd.uniform(-0.006, 0.006))


def build(today: dt.date, count: int, rnd: random.Random) -> Library:
    library = Library()
    shots, clips = library.shots, library.clips

    def home() -> tuple[float, float]:
        return jitter(rnd, HOME)

    # Anniversaries: same calendar day, 1..5 years back. Three frames each is below
    # `EventClustering.minimumCount`, so these feed On This Day rather than occasions.
    for years in (1, 2, 3, 5):
        try:
            day = today.replace(year=today.year - years)
        except ValueError:                      # 29 Feb
            day = today.replace(year=today.year - years, day=28)
        for k in range(3):
            shots.append(Shot(dt.datetime.combine(day, dt.time(11 + k * 3, 20 + k * 7)),
                              100 + years * 10 + k, gps=home(),
                              note=f"anniversary {years}y"))

    # One dense evening, two years ago: an event worth clustering, with a clip in it so the
    # occasion has a video and `EventClustering.significance` picks up its variety bonus.
    evening = dt.datetime.combine(today.replace(year=today.year - 2), dt.time(20, 2))
    for k in range(12):
        shots.append(Shot(evening + dt.timedelta(minutes=4 * k + rnd.randint(0, 3)),
                          300 + k, gps=home(), note="dense evening"))
    clips.append(Clip("IMG_0451.MOV", evening + dt.timedelta(minutes=26), 341,
                      gps=jitter(rnd, HOME), note="camera clip inside the evening"))

    # Five near-identical frames last year: duplicates to collapse.
    burst = dt.datetime.combine(today.replace(year=today.year - 1), dt.time(16, 41))
    for k in range(5):
        shots.append(Shot(burst + dt.timedelta(seconds=6 * k), 777, drift=0.35 * k,
                          gps=home(), note="near-duplicate burst"))

    # A day out in the second town: a distinct Place, but only ~76 km from home, so it must
    # *not* come out as a trip.
    outing = dt.datetime.combine(today - dt.timedelta(days=200), dt.time(13, 5))
    for k in range(5):
        shots.append(Shot(outing + dt.timedelta(minutes=11 * k), 420 + k,
                          gps=jitter(rnd, NEARBY), note="nearby town"))
    clips.append(Clip("IMG_0620.MOV", outing + dt.timedelta(minutes=33), 424,
                      gps=jitter(rnd, NEARBY), note="camera clip, second place"))

    # Two consecutive days far away. Each day is its own occasion; they are less than
    # `TripFinder.maxGap` apart and span two calendar days, which is what makes them a trip.
    trip = dt.datetime.combine(today - dt.timedelta(days=430), dt.time(15, 10))
    for k in range(4):
        shots.append(Shot(trip + dt.timedelta(minutes=9 * k), 500 + k,
                          gps=jitter(rnd, FAR), note="trip day 1"))
    for k in range(4):
        shots.append(Shot(trip + dt.timedelta(days=1, hours=-5, minutes=12 * k), 510 + k,
                          gps=jitter(rnd, FAR), note="trip day 2"))

    # Filenames in the shapes `ProvenanceReader.platform(forFilename:)` knows. The two
    # WhatsApp stills are dated *recently* in EXIF while their names carry a date from years
    # ago — which is exactly the case `dateFromFilename` exists for, and the only one that
    # produces a corrected date without depending on how Photos reads a video container.
    # No GPS on any of them: messaging apps strip it, and so does this fixture.
    saved_recently = dt.datetime.combine(today - dt.timedelta(days=6), dt.time(9, 12))
    shots.append(Shot(saved_recently, 900, name="IMG-20230114-WA0007.jpg",
                      note="WhatsApp, name says 2023-01-14"))
    shots.append(Shot(saved_recently + dt.timedelta(days=-3, hours=4), 901,
                      name="IMG-20220803-WA0021.jpg",
                      note="WhatsApp, name says 2022-08-03"))
    shots.append(Shot(dt.datetime.combine(today - dt.timedelta(days=44), dt.time(18, 31)),
                      902, name="photo_2024-02-11_18-31-05.jpg", note="Telegram"))
    shots.append(Shot(dt.datetime.combine(today - dt.timedelta(days=88), dt.time(21, 4)),
                      903, name="Snapchat-1749302281.jpg", note="Snapchat"))
    shots.append(Shot(dt.datetime.combine(today - dt.timedelta(days=120), dt.time(12, 46)),
                      904, name="FB_IMG_1691500000.jpg", note="Facebook"))
    shots.append(Shot(dt.datetime.combine(today - dt.timedelta(days=310), dt.time(15, 28)),
                      905, name="received_10159123456789012.jpeg", note="Messenger"))

    # Clips whose container disagrees with their file dates. `saved` is when they landed on
    # the phone; `recorded` is the truth the app has to dig out.
    clips.append(Clip("VID-20230512-WA0011.MOV",
                      saved=dt.datetime.combine(today - dt.timedelta(days=5), dt.time(20, 41)),
                      seed=610,
                      recorded=dt.datetime(2022, 11, 3, 18, 24, 10),
                      note="WhatsApp clip, container says 2022-11-03"))
    clips.append(Clip("VID-20220730-WA0004.MOV",
                      saved=dt.datetime.combine(today - dt.timedelta(days=12), dt.time(11, 8)),
                      seed=611,
                      recorded=dt.datetime(2022, 7, 29, 16, 2, 45),
                      metadata_style="mdta",
                      note="WhatsApp clip, QuickTime metadata key only"))
    clips.append(Clip("RPReplay_Final1690000000.MOV",
                      saved=dt.datetime.combine(today - dt.timedelta(days=3), dt.time(22, 15)),
                      seed=612,
                      recorded=dt.datetime(2023, 7, 27, 19, 55, 0),
                      note="screen recording, container says 2023-07-27"))

    # Whatever is left over, scattered over six years so the timeline and calendar fill in.
    # Most read as this phone's own camera; a couple carry no recognisable name at all, which
    # is the `SourcePlatform.download` case.
    filler = max(0, count - len(shots) - len(clips))
    for index in range(filler):
        back = rnd.randint(1, 6 * 365)
        when = dt.datetime.combine(today - dt.timedelta(days=back),
                                   dt.time(rnd.randint(7, 22), rnd.randint(0, 59)))
        anonymous = index % 3 == 2
        shots.append(Shot(
            when, rnd.randint(0, 9999),
            name=f"image_{1_690_000_000 + index * 8641}.jpeg" if anonymous else None,
            gps=home() if index % 3 == 0 else None,
            note="filler, no recognisable name" if anonymous else "filler",
        ))

    return library


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=60,
                    help="total assets, photos and videos together")
    ap.add_argument("--today", default=None, help="YYYY-MM-DD, defaults to now")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    rnd = random.Random(20260807)

    library = build(today, args.count, rnd)
    library.shots.sort(key=lambda shot: shot.when)

    manifest: list[str] = []
    for index, shot in enumerate(library.shots):
        name = shot.name or f"IMG_{4000 + index:04d}.JPG"
        path = os.path.join(args.out, name)
        save(frame(shot.seed, shot.drift), path, shot.when, shot.gps)
        manifest.append(f"  {name:34s} {shot.when:%Y-%m-%d %H:%M}"
                        f"  {'gps' if shot.gps else '   '}  {shot.note}")

    for clip in library.clips:
        path = os.path.join(args.out, clip.name)
        write_clip(path, clip.seed, clip.saved, clip.recorded, clip.metadata_style, clip.gps)
        recorded = f"container {clip.recorded:%Y-%m-%d}" if clip.recorded else "no container date"
        manifest.append(f"  {clip.name:34s} {clip.saved:%Y-%m-%d %H:%M}"
                        f"  video  {clip.note} ({recorded})")

    located = sum(1 for shot in library.shots if shot.gps) + sum(1 for c in library.clips if c.gps)
    print("\n".join(manifest))
    print(f"\nwrote {len(library.shots)} photos and {len(library.clips)} videos "
          f"to {args.out} ({located} with coordinates)")
    print(NOT_COVERED)


if __name__ == "__main__":
    main()
