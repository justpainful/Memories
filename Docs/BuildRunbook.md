# Build Runbook

## Scope

This repository is generated with XcodeGen and ships one iPhone app target only: `Memories` with bundle identifier `space.hi.memories`.

## Local macOS workflow

1. Run `Scripts/bootstrap.sh`.
2. Run `Scripts/generate_project.sh`.
3. Run `Scripts/verify_bundle_identity.sh`.
4. Open `Memories.xcodeproj` in Xcode 26 or build from the command line.

To package the unsigned device artifact on macOS:

1. Run `Scripts/build_unsigned_ipa.sh`.
2. Inspect `artifacts/` for:
   - `Memories-<marketing-version>-<build-number>-unsigned.ipa`
   - matching `.sha256`
   - matching `.manifest.json`

To validate an existing IPA:

1. Run `Scripts/verify_ipa.sh /absolute/path/to/Memories-...-unsigned.ipa`.

## CI and GitHub Actions

- `/.github/workflows/ci.yml` is the authoritative repository validation path.
- `/.github/workflows/build-unsigned-ipa.yml` is the authoritative unsigned IPA packaging path.
- Both workflows accept `EXPECTED_BUNDLE_ID` from repository variables and fall back to `space.hi.memories` when it is unset.
- Both workflows fail early if the macOS runner does not expose an iOS 26 SDK.

## Failure guidance

- If `bootstrap.sh` fails, fix Xcode or XcodeGen availability first.
- If `verify_bundle_identity.sh` fails, restore the canonical identity values before investigating build issues.
- If `build_unsigned_ipa.sh` fails, inspect `build/logs/unsigned-ipa-build.log` and the `.xcresult` bundle under `build/results/`.
