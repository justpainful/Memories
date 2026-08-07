# Memories — Design Brief (for Claude Design)

Paste everything below the line into Claude Design. It is self-contained.

---

## The product

**Memories** is a standalone iPhone app (iOS 26, portrait only, light + dark) that reads the user's
existing Photos library **entirely on-device** and turns it into a personal, daily-changing magazine
of memories. It never uploads anything, has no accounts, no backend, no cloud AI, no social layer.

It is **not** a second Photos app and **not** a grid browser. Its reason to exist is one idea:

> **Time is the interface.** Remember · Explore · Rediscover.

The app understands the library — it clusters near-duplicate shots and picks the best frame, groups
bursts of shooting into *events*, scores photos for quality/aesthetics/face quality, and assembles
memories like "A year ago today", "A night you photographed a lot", "August over the years".

Tone: quiet, warm, editorial, personal. The opposite of a dashboard. Closest references are Apple's
own Photos / Journal / Books — **not** a startup product, not a SaaS, not a "dark mode neon" app.

## Hard constraints (do not design around these — design *with* them)

- iPhone only, **portrait only**, safe areas respected. No landscape layouts.
- iOS 26 **Liquid Glass** is the only glass allowed. Glass is the *control layer* — floating nav bar,
  filter chips, viewer controls, toolbars, menus, segmented controls. **Never** a glass background
  behind content cards, never a full-screen glass panel. If more than ~15% of a screen is glass, it's wrong.
- No frosted-blur fakes, no translucent gray rectangles pretending to be glass, no gradient "glass".
- Photos supply the color. The chrome is near-neutral. There is no brand gradient.
- No purple/blue tech gradients, no bento grids, no glowing cards, no 3-feature-card rows,
  no floating pill navbars that look like a marketing site, no fake data dashboards.

## Locked design tokens (already implemented — please match exactly)

**The chrome is the system's — there is no house colour.** Every value below is a UIKit
system colour, which is what makes the app read as part of iOS instead of as a branded
product. All the colour on screen comes from the photographs themselves (the feed's top
carries a faint wash sampled from the hero image) and from nowhere else.

| Token | Light | Dark |
|---|---|---|
| Canvas | `systemBackground` — pure white | pure black |
| Raised surface | `secondarySystemGroupedBackground` | same |
| Text primary / secondary / tertiary | `label` / `secondaryLabel` / `tertiaryLabel` | same |
| Tint (links, toggles, selection) | system blue `#007AFF` | `#0A84FF` |
| Hairline | `separator` | same |

Do **not** introduce an accent hue of your own — no orange, no teal, no brand gradient.
The app icon is warm, the interface is not; that is the same split Photos uses.

- **Type — two families, strictly separated:**
  - **New York (serif)** — the *editorial* layer only: memory titles, section headlines,
    the date headline on Home, memory covers. Sizes 34/28/22, weight regular→semibold, tight leading.
  - **SF Pro** — everything functional: tab bar, buttons, settings, counts, metadata, captions.
  - Never mix the two inside one line.
- **Radii:** hero 28 · card 22 · tile 14 · thumbnail 10 · glass controls = capsule.
- **Spacing scale:** 4 · 8 · 12 · 16 · 20 · 28 · 40. Screen gutter 20. Section spacing 40.
- **Motion:** spring, ~0.35s, no bounce-heavy easing. Glass morphs shape instead of new sheets appearing.

## Screens to design (in priority order)

1. **Home — "Memories"** — the most important screen. A vertically scrolling *magazine*, not a grid.
   Composed of variable-height sections stacked in an editorial rhythm:
   - Date headline (serif, e.g. "Friday, August 7")
   - **Hero memory**: one full-bleed 4:5 image, title overlaid low-left ("Two years ago today"),
     subtitle ("24 moments · Riyadh"). A very subtle ambient color wash, sampled from this photo,
     bleeds into the top of the screen behind the status bar.
   - **"This week through the years"**: a horizontal row of year-labelled cards (2025 / 2024 / 2023).
   - **Event mosaic**: "A night worth remembering" — an asymmetric 3–5 photo mosaic (one large left,
     two stacked right), with a time+place caption.
   - **Month-through-years block**: "August over the years", stacked year rows with small thumb strips.
   - Floating Liquid Glass tab bar at the bottom: Memories · Timeline · Library.
2. **Explore Time** — the signature interaction. Tapping the compass/clock control in the glass bar
   makes the **tab bar itself morph** into a taller glass panel listing time jumps
   (Today / This Week / This Month / This Year — On This Day / This Week Through Years / Same Season —
   1, 2, 3, 5, 10 Years Ago — Surprise Me), grouped with hairline dividers. It is one continuous piece
   of glass that grew, not a sheet that slid up. Show the morph mid-state if you can.
3. **Memory Viewer** — full-screen, edge-to-edge photo on black. No chrome except a single floating
   glass cluster at the bottom: back · heart · more. Controls fade out after 2.5s and return on tap.
4. **Timeline** — vertical years → months → days, thumbnails scattered in a calm rhythm, with a
   fast year scrubber on the right edge.
5. **Library** — sectioned entry points (All, Photos, Videos, Live Photos, Screenshots, Collections,
   Hidden) shown as a list with small cover thumbnails, plus Calendar / Places / Search entries.
6. **Calendar** — month grid where each day that has photos shows a tiny cover thumbnail instead of
   a number; tapping a day opens that date across every year.
7. **Onboarding** — 3 quiet lines, serif headline "Your photos. Remembered privately.",
   then a single prominent glass button "Allow Photo Access". No illustrations of robots or clouds.
8. **Settings / Privacy dashboard** — plain grouped iOS list, Apple Settings-app fidelity. The Privacy
   screen states real counts: items processed on this iPhone, **Uploaded: 0**, External AI services: None.

## What to deliver

For each screen: a light-mode and dark-mode still, portrait iPhone. Realistic photo content
(personal snapshots — evenings out, travel, food, people — **not** stock-looking hero images).
Real English copy, no lorem ipsum. Annotate where Liquid Glass is used and where it deliberately isn't.

If you propose a change to a locked token, say so explicitly and why — otherwise stay inside them.
