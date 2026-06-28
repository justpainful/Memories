# Phase 1 Completion

## Completed repository work

- XcodeGen project spec with one iPhone app target and two test bundles.
- Immutable bundle identity lock in `Config/AppIdentity.xcconfig`.
- GitHub Actions CI and unsigned IPA workflows.
- Local-first app shell with four tabs only: Memories, Library, Blocked, Profile.
- Native Liquid Glass design system for iOS 26.
- English-only onboarding flow with custom PhotoKit-backed avatar picker seam.
- Photo library service, change observation seam, recovery matching, SwiftData persistence, deterministic curation engine, and temporary share export path.
- Feed playback shell for photos, videos, and Live Photos with process-lifetime mute coordination and previous/current/next preload.
- Library, Blocked, and Profile surfaces backed by local reference state.
- Unit and UI smoke test scaffolding for mock data paths.

## Not proven from this Windows host

- `xcodegen` generation
- `xcodebuild` compile
- simulator UI tests
- unsigned IPA packaging
- workflow execution on macOS

Those remain unverified locally because this machine does not currently have `swift`, `xcodegen`, `bash`, or Xcode tooling installed.

## Brand status

- `Design/Brand/memories-logo-reference.png` is missing.
- App icon derivation is therefore blocked and documented in `Docs/BrandAssetStatus.md`.

## Integration notes

- `AppModel` owns the mock smoke-test launch hooks through `MEMORIES_UI_TEST_SCENARIO` and `UITests*` launch arguments.
- `MemoryRepository` is the canonical local state store and also backs cycle persistence.
- `PhotoLibraryService` performs conservative recovery matching and will prefer `nil` over guessing when a restoration match is ambiguous.
- `TemporaryMediaSharingClient` writes only temporary share files and cleans them up on demand.

## Manual follow-up after first macOS CI run

1. Confirm exact iOS 26 Liquid Glass API signatures under the installed Xcode 26 toolchain.
2. Generate the project and fix any compile drift from SDK naming or Swift 6 diagnostics.
3. Add the missing canonical logo asset and regenerate the AppIcon set.
4. Run the unsigned IPA workflow and verify the uploaded artifact manifest.

