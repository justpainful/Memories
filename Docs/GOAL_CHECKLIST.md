# Goal checklist

Derived from `Docs/GOAL.txt`. Status reflects the code, verified by reading it — not by
intention. Anything not done says why.

Legend: ✅ done · 🟡 partial · ⬜ not done

## Foundations
- ✅ 1. Native SwiftUI, iOS 26 deployment target, no login, no backend, no analytics
- ✅ 1. No networking anywhere in the app. The only outbound call is `CLGeocoder`, which
  sends coordinates the camera already saved in order to name a place. No photo ever leaves.
- ✅ 1. Full and Limited photo access both handled as first-class modes
- ✅ 1. `isNetworkAccessAllowed = false` for all indexing; iCloud originals are never pulled
  down behind the user's back. Explicitly opening a photo full screen is allowed to fetch it.
- ✅ 3. No second copy of the library — identifiers and computed metadata only
- ✅ 32. SwiftData models present. `MemoryCandidate` is a value type rather than a stored
  model, because a proposal that loses every ranking contest should not survive on disk.

## Onboarding and indexing
- ✅ 2. "Your photos. Remembered privately." + three lines + one button
- ✅ 2. "Getting your memories ready" — never a scan counter; the feed rebuilds as indexing lands
- ✅ 30. Six stages. Feature prints and quality share one pass because they share one decode;
  decoding a large library twice to keep two stage names apart is paid for in heat and battery.
- ✅ 31. Diffed, not rebuilt: `analysisVersion` plus change observing; an asset edited in
  Photos has its derived data invalidated rather than the whole index
- 🟡 31. The delta is computed and stored but only the removal count is surfaced
- ✅ 33. Thumbnail-resolution analysis, batching, background tasks, thermal/battery/Low Power aware

## Home
- ✅ 4/29. Hero, through-the-years strips, event mosaics, month-over-years blocks
- ✅ 4. Different day to day — exposure is a scoring component, not an afterthought
- ✅ 29. Photographs supply the colour; an ambient wash is sampled from the hero cover

## Time and filters
- ✅ 5. Today, Yesterday, This/Last Week, This/Last Month, This/Last Year
- ✅ 5. On This Day, 1/2/3/5/10 Years Ago, This Week Last Year, This Week/Month/Season in
  Previous Years, Same Weekend in Previous Years
- 🟡 5. Cross-year: "Every August" is reachable for the current month. All twelve exist in
  `everyMonthWindows` but only one is surfaced — twelve rows would bury the Explore panel.
- ✅ 6. Best Of as a screen the user picks from: day, week, month, year, trip, place, occasion.
  A trip is a run of occasions spanning two or more days more than 100 km from the median of
  every located photo — a median, so one month abroad cannot drag "home" across a continent.
- ✅ 6. Forgotten, Rarely Seen, Recently Rediscovered — all three, and distinct from each other
- ✅ 6. Smart Random avoids screenshots, duplicates, weak frames and anything seen this week
- ✅ **Signature.** Explore Time morphs out of the tab bar's own glass

## Understanding the library
- ✅ 7. Events from time gaps, distance, shooting density and visual continuity
- ✅ 8. Similarity clusters with an elected Best Shot; nothing deleted; "Show all N"
- ✅ 9. Vision `GenerateImageFeaturePrintRequest` → stored vectors → clusters
- ✅ 10. Memory Quality Score blends aesthetics, sharpness, exposure, faces, face quality,
  subject prominence, composition, resolution, screenshot penalty, duplicate count and burst
  position. Prominence and composition come from Vision's saliency requests on the frame the
  other passes already decoded. Composition is a rule of thumb about where photographers put
  things, not a verdict on whether a picture works, so it is weighted to break a tie and no more.
- ✅ 10. `CalculateImageAestheticsScoresRequest` used; no score is ever shown to the user
- ✅ 11. Face capture quality decides between near-identical portraits
- ✅ 24. Videos analysed from a representative frame, scored, and given event membership

## Viewing
- ✅ 12. Pure / Smart, switchable in place
- ✅ 13. Full screen, floating glass controls, swipe, native video, native Live Photo
- 🟡 13. `•••` — all eight present and working. "Show in Photos" attempts a direct link to
  the asset and falls back to opening Photos if the system refuses, because iOS publishes no
  documented URL for one asset. The fallback means the control always does something.
- ✅ 14. Hide ≠ Delete, with a Hidden Memories screen and per-tile Restore
- ✅ 15. Collections hold photos, videos, occasions, days and memories
- 🟡 16. Timeline: year → month → day with a drag scrubber
- ✅ 17. Calendar with per-day covers and a day-across-years drill-down
- ✅ 18. Places: map, per-place per-year counts, each row opening that place in that year
- ✅ 19. Search over date (including a specific day, across all years), month, year, media
  type, location, favourites, screenshots, videos, Live Photos and collections

## The engine
- ✅ 20. Twelve candidate generators — the eleven named plus Rarely Seen
- ✅ 20. All seven score components computed and weighted
- ✅ 21. Exposure tracked per memory and per asset; a memory needs a reason to return
- ✅ 22. Local learning across six clamped signals, all read by ranking, all erasable
- ✅ 23. Screenshots out of memories by default, with their own section and switch

## Shell
- ✅ 25. Real Liquid Glass only. No `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`,
  `.blur`, or any translucent rectangle standing in for glass — verified by audit.
- ✅ 26. Glass is the control layer. Feed cards are never glass.
- ✅ 27. Glass morphing is the signature transition — one `glassEffectID` across both states
- ✅ 28. Three tabs; Calendar, Places and Search live inside Timeline and Library
- ✅ 34. Storage: database, analysis cache, thumbnails, total, and Clear Analysis Cache
- ✅ 35. Privacy dashboard with real counters, including Uploaded: 0
- ✅ 36. Settings tree as specified
- ✅ 37. None of the rejected features present

## Added by the user, outside the spec file
- ✅ Local notifications only. No APNs, no server: the app works out what it would show on
  each of the next days and writes that text into a local request. Off until asked for.
- ✅ App icon — flat glyph on a gradient, light/dark/tinted
- ✅ No screen letterboxed or black-barred — `UILaunchScreen` present, verified from CI screenshots
- 🟡 Nothing ships broken. One audit pass found and fixed every dead control it could reach;
  a second pass over the current build is the remaining work.
