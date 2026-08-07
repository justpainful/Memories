# Goal checklist

Derived from `Docs/GOAL.txt`. The goal is complete only when every line is ✅. A line may be
dropped only for a hard block that cannot be worked around, and the block must be stated.

Legend: ⬜ not started · 🟡 in progress · ✅ done · ⛔ blocked (reason required)

## Foundations
- ⬜ 1. Native SwiftUI, iOS 26+, fully local, no login/backend/analytics/uploads/AI-API/cloud
- ⬜ 1. Full Photo Access **and** Limited Access both supported
- ⬜ 1. `isNetworkAccessAllowed = false` everywhere — iCloud originals never auto-downloaded
- ⬜ 3. No second copy of the library; store identifiers + computed metadata only
- ⬜ 32. SwiftData models: AssetRecord, EventCluster, SimilarityCluster, MemoryRecord,
  MemoryCandidate, CollectionRecord, ExposureRecord, AnalysisState, UserPreference

## Onboarding and indexing
- ⬜ 2. Calm onboarding: "Your photos. Remembered privately." + 3 lines + Allow Photo Access
- ⬜ 2. "Getting your memories ready" — no `Scanning 1 of 52,492`; memories appear progressively
- ⬜ 30. Six analysis stages: metadata → thumbnails → similarity → quality → events → memories
- ⬜ 31. `analysisVersion` + change observing; only deltas are re-analyzed
- ⬜ 33. Thumbnail-resolution analysis, batching, background tasks, caching, thermal + battery aware

## Home
- ⬜ 4/29. Editorial feed: hero, through-the-years strips, event mosaics, month-over-years
- ⬜ 4. The page differs day to day
- ⬜ 29. Photos supply the colour; chrome stays neutral

## Time and filters
- ⬜ 5. Time filters: Today, Yesterday, This/Last Week, This/Last Month, This/Last Year
- ⬜ 5. Historical: On This Day, 1/2/3/5/10 Years Ago, This Week Last Year,
  This Week/Month/Season in Previous Years, Same Weekend in Previous Years
- ⬜ 5. Cross-year: Every August, Your Januarys, …
- ⬜ 6. Best of day/week/month/year/trip/place/event
- ⬜ 6. Forgotten, Rarely Seen, Recently Rediscovered
- ⬜ 6. Smart Random that avoids screenshots, duplicates, weak shots, recently seen
- ⬜ **Signature.** Explore Time — one glass control that morphs out of the tab bar

## Understanding the library
- ⬜ 7. Events from time gaps, place, shooting density, visual similarity, people, media type
- ⬜ 8. Similarity clusters with a chosen Best Shot; the rest hidden, never deleted; "Show all N"
- ⬜ 9. Vision `GenerateImageFeaturePrintRequest` → similarity index → clusters
- ⬜ 10. Memory Quality Score: sharpness, exposure, composition, faces, subject prominence,
  resolution, screenshot penalty, duplicate penalty, burst position, aesthetics
- ⬜ 10. `CalculateImageAestheticsScoresRequest` used; scores stay internal
- ⬜ 11. Face capture quality prioritises the better frame of near-identical people shots
- ⬜ 24. Videos: limited frame analysis, representative frame, quality, duration, event membership

## Viewing
- ⬜ 12. Pure / Smart toggle, switchable instantly
- ⬜ 13. Full-screen viewer, floating glass controls, swipe, native video, native Live Photo
- ⬜ 13. `•••`: Show in Photos, Share, Hide from Memories, Show Similar, Show Event,
  Show This Day, Use as Cover, Details
- ⬜ 14. Hide ≠ Delete — `excludedFromMemories`, plus a Hidden Memories screen with Restore
- ⬜ 15. Collections holding photos, videos, events, days and smart memories
- ⬜ 16. Timeline with year → month → day and fast scrubbing
- ⬜ 17. Calendar with per-day cover thumbnails and a day-across-years drill-down
- ⬜ 18. Places from existing location metadata, native map, per-year counts
- ⬜ 19. Local search: date, month, year, media type, location, favourites, screenshots,
  videos, live photos, collections

## The engine
- ⬜ 20. `MemoryEngine` with the eleven candidate generators
- ⬜ 20. Candidate scoring: relevance, quality, novelty, time significance, media diversity,
  duplicate density, recent exposure
- ⬜ 21. Exposure tracking so the same memory is not repeated the next day without reason
- ⬜ 22. Local preference learning + Reset Memory Suggestions
- ⬜ 23. Screenshots excluded by default, own section, Settings toggle

## Shell
- ⬜ 25. Real Liquid Glass only — no `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`,
  `.blur`, opacity or gradient fakes
- ⬜ 26. Glass is the control layer, not the background of every card
- ⬜ 27. Glass morphing as the app's signature transition
- ⬜ 28. Three tabs: Memories, Timeline, Library
- ⬜ 34. Storage breakdown + Clear Analysis Cache
- ⬜ 35. Privacy dashboard with real counters
- ⬜ 36. Settings tree exactly as specified
- ⬜ 37. None of the rejected features present

## Added by the user, outside the spec file
- ⬜ Local notifications only (no APNs, no backend) — scheduled from the local database
- ⬜ App icon
- ⬜ Nothing ships broken: no crashing or dead controls
- ⬜ No screen letterboxed, cropped, or black-barred — verified from CI screenshots
