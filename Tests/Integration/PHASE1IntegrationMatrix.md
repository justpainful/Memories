# Phase 1 Integration Matrix

## Deterministic mock paths

- `MEMORIES_UI_TEST_SCENARIO=onboarding-mock`
  - starts from onboarding with mock avatar candidates and mock library data
- `MEMORIES_UI_TEST_SCENARIO=app-mock`
  - starts from a completed-onboarding mock profile and mock library data
- Launch arguments:
  - `UITestsSkipOnboarding`
  - `UITestsStartLibrary`
  - `UITestsStartBlocked`
  - `UITestsStartProfile`
  - `UITestsProfileName <name>`

## Required macOS validation

1. `Scripts/bootstrap.sh`
2. `Scripts/generate_project.sh`
3. `Scripts/verify_bundle_identity.sh`
4. `xcodebuild test` for `MemoriesUnitTests`
5. `xcodebuild test` for `MemoriesUITests`
6. `Scripts/build_unsigned_ipa.sh`
7. `Scripts/verify_ipa.sh <ipa path>`

## Real-device checklist

- Confirm PhotoKit authorization flows for authorized, limited, denied, and restricted.
- Confirm Live Photo long-press playback.
- Confirm process-lifetime mute persistence across background/foreground.
- Confirm blocking removes an item from the active feed without deleting it from Photos.
- Confirm temporary share exports are created only on explicit share and are cleaned up afterward.
- Confirm no asset bytes are persisted outside temporary share exports.
