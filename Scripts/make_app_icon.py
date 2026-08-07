#!/usr/bin/env python3
"""Render the Memories app icon in the Apple system-app idiom.

Apple's own icons (Books, Music, Podcasts, Shortcuts, Journal) are one flat glyph
on a clean vertical gradient: no drop shadows, no bevels, no 3D stacking, generous
margins, and overlapping shapes separated by knocked-out hairline gaps rather than
by shading.

Mark: a fan of three prints, drawn as solid white with gradient-coloured gaps, and
one small circle knocked out of the front print so it reads as a photograph rather
than as a stack of documents.

    python Scripts/make_app_icon.py
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw

SIZE = 1024
SS = 3
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Memories", "Resources", "Assets.xcassets", "AppIcon.appiconset")

# three-stop vertical gradients, light -> deep, in the app's Ember family
BACKDROPS = {
    "light": [(0xFF, 0xC9, 0x78), (0xF2, 0x86, 0x3C), (0xD0, 0x48, 0x22)],
    "dark":  [(0xC9, 0x93, 0x50), (0xA8, 0x54, 0x25), (0x77, 0x2A, 0x14)],
}

# Two prints of equal size, offset on the diagonal so the one behind peeks out as an
# even band top-left. Painted back to front; the front one carries the photograph.
CARD_W, CARD_H, CARD_R = 0.455, 0.455, 0.108
OFFSET = 0.082          # each print sits this far from centre along the diagonal
GAP = 0.030             # knocked-out hairline around the front print


def gradient(size, stops):
    """Vertical multi-stop gradient, built as a 1xN strip then stretched."""
    n = 512
    strip = Image.new("RGB", (1, n))
    px = strip.load()
    seg = n / (len(stops) - 1)
    for i in range(n):
        k = min(int(i / seg), len(stops) - 2)
        t = (i - k * seg) / seg
        a, b = stops[k], stops[k + 1]
        px[0, i] = (round(a[0] + (b[0] - a[0]) * t),
                    round(a[1] + (b[1] - a[1]) * t),
                    round(a[2] + (b[2] - a[2]) * t))
    return strip.resize((size, size), Image.BILINEAR)


def card_silhouette(canvas, w, h, r, cx, cy, angle, grow=0):
    """A rotated rounded rectangle as an L mask on a full canvas, optionally inflated."""
    gw, gh, gr = w + grow * 2, h + grow * 2, r + grow
    layer = Image.new("L", (canvas, canvas), 0)
    shape = Image.new("L", (gw, gh), 0)
    ImageDraw.Draw(shape).rounded_rectangle([0, 0, gw - 1, gh - 1], radius=gr, fill=255)
    layer.paste(shape, (cx - gw // 2, cy - gh // 2))
    return layer.rotate(angle, resample=Image.BICUBIC, center=(cx, cy))


def build_mark(s):
    """White glyph as an alpha mask, auto-fitted and optically centred on s x s."""
    mark = Image.new("L", (s, s), 0)
    cw, ch, cr, off = s * CARD_W, s * CARD_H, s * CARD_R, s * OFFSET
    gap = s * GAP

    def rect(dx, dy, grow=0.0):
        x, y = s / 2 + dx, s / 2 + dy
        return [x - cw / 2 - grow, y - ch / 2 - grow, x + cw / 2 + grow, y + ch / 2 + grow]

    d = ImageDraw.Draw(mark)
    d.rounded_rectangle(rect(-off, -off), radius=cr, fill=255)
    d.rounded_rectangle(rect(off, off, gap), radius=cr + gap, fill=0)
    d.rounded_rectangle(rect(off, off), radius=cr, fill=255)

    left, top, right, bottom = rect(off, off)
    fcx = (left + right) / 2

    # The photograph inside the print: a soft hill and a sun, both knocked back out to
    # the gradient. Two colours only — it still reads at 40px.
    scene = Image.new("L", (s, s), 0)
    sd = ImageDraw.Draw(scene)
    hx, hy = fcx - cw * 0.12, top + ch * 1.02
    rx, ry = cw * 0.74, ch * 0.355
    sd.ellipse([hx - rx, hy - ry, hx + rx, hy + ry], fill=255)
    sr = cw * 0.128
    sx, sy = fcx + cw * 0.235, top + ch * 0.285
    sd.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=255)

    clip = Image.new("L", (s, s), 0)
    inset = cw * 0.085
    ImageDraw.Draw(clip).rounded_rectangle(
        [left + inset, top + inset, right - inset, bottom - inset],
        radius=cr - inset * 0.75, fill=255)
    mark.paste(0, (0, 0), Image.composite(scene, Image.new("L", (s, s), 0), clip))

    cropped = mark.crop(mark.getbbox())
    scale = min(s * 0.640 / cropped.width, s * 0.640 / cropped.height)
    cropped = cropped.resize((round(cropped.width * scale), round(cropped.height * scale)),
                             Image.LANCZOS)
    fitted = Image.new("L", (s, s), 0)
    fitted.paste(cropped, ((s - cropped.width) // 2, (s - cropped.height) // 2))
    return fitted


def render(variant):
    s = SIZE * SS
    stops = BACKDROPS["dark" if variant == "dark" else "light"]
    base = gradient(s, stops).convert("RGB")
    base.paste((255, 255, 255), (0, 0), build_mark(s))

    icon = base.resize((SIZE, SIZE), Image.LANCZOS)
    if variant == "tinted":
        g = icon.convert("L")
        icon = Image.merge("RGB", (g, g, g))
    return icon


def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m


def contact_sheet():
    light = Image.open(os.path.join(OUT_DIR, "AppIcon-Light.png"))
    dark = Image.open(os.path.join(OUT_DIR, "AppIcon-Dark.png"))
    sizes = (180, 120, 80, 60, 40)
    width = 32 + sum(px + 28 for px in sizes)
    sheet = Image.new("RGB", (width, 300), (0xEF, 0xEF, 0xF2))
    ImageDraw.Draw(sheet).rectangle([0, 150, width, 300], fill=(0x1C, 0x1C, 0x1E))
    for row, img in ((0, light), (1, dark)):
        x = 32
        for px in sizes:
            sheet.paste(img.resize((px, px), Image.LANCZOS),
                        (x, row * 150 + (150 - px) // 2),
                        rounded_mask(px, px, int(px * 0.2237)))
            x += px + 28
    path = os.path.join(ROOT, "Docs", "icon-preview.png")
    sheet.save(path)
    print(f"wrote {path}")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for variant, name in (("light", "AppIcon-Light.png"),
                          ("dark", "AppIcon-Dark.png"),
                          ("tinted", "AppIcon-Tinted.png")):
        path = os.path.join(OUT_DIR, name)
        render(variant).save(path, "PNG", optimize=True)
        print(f"wrote {path}")
    contact_sheet()


if __name__ == "__main__":
    main()
