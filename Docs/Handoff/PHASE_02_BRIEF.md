# Phase 2 Brief

## Scope

Phase 2 should deepen curation quality and production hardening without redoing Phase 1 foundations.

## Ready seams from Phase 1

- `MemoryCurationEngine` accepts injected scoring and randomization.
- `PhotoLibraryService` exposes recovery matching and change observation seams.
- `MemoryRepository`, `ProfileRepository`, and `ThemeRepository` isolate local persistence.
- UI smoke launch hooks already support deterministic app states.

## Priority work

1. Add `VisionAestheticRanker` behind the existing scoring seam and validate it against real libraries before making claims about quality.
2. Improve duplicate/event clustering beyond burst-plus-time-bucket heuristics.
3. Add deletion/restoration integration tests using real-device or simulator-backed PhotoKit scenarios.
4. Add performance measurement for large libraries and feed preload behavior.
5. Replace the blocked AppIcon placeholder path with the real canonical logo asset and Apple-current icon tooling output.

## Explicitly out of scope unless approved

- iCloud sync
- Google Drive sync
- notifications or digests
- backend accounts
- analytics

