# Memories

Memories is a private, local-first iPhone application for resurfacing meaningful photos, videos, and Live Photos from Apple Photos without duplicating the media into app storage.

Phase 1 guardrails:

- one iPhone target only
- immutable bundle identifier `space.hi.memories`
- SwiftUI plus native iOS 26 Liquid Glass
- PhotoKit-backed onboarding, feed, library, blocked, and profile experiences
- deterministic local curation with persistent viewed cycles
- unsigned IPA packaging through GitHub Actions on macOS

Build entry points:

- `Scripts/bootstrap.sh`
- `Scripts/generate_project.sh`
- `Scripts/verify_bundle_identity.sh`
- `Scripts/build_unsigned_ipa.sh`
- `Scripts/verify_ipa.sh /absolute/path/to/Memories-...-unsigned.ipa`

Operational docs:

- [Docs/BuildRunbook.md](Docs/BuildRunbook.md)
- [Docs/GitHubProtectionSetup.md](Docs/GitHubProtectionSetup.md)
- [Docs/BrandAssetStatus.md](Docs/BrandAssetStatus.md)
