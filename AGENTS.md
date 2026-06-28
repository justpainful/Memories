# Memories Agent Guardrails

This repository ships one iPhone application target only.

Protected identity rules:

- App name: `Memories`
- Bundle identifier: `space.hi.memories`
- Platform: iPhone only
- Minimum OS: iOS 26.0
- Language surface: English only

Never:

- introduce a second app target
- introduce any extension target
- change `space.hi.memories`
- rename the app away from `Memories`
- add cloud, sync, analytics, or third-party UI frameworks

Protected paths require code-owner approval:

- `/Config/AppIdentity.xcconfig`
- `/project.yml`
- `/AGENTS.md`
- `/Scripts/verify_bundle_identity.sh`
- `/.github/workflows/`
- `/.github/CODEOWNERS`
- `/Docs/BuildRunbook.md`
- `/Docs/GitHubProtectionSetup.md`
- `/Docs/BrandAssetStatus.md`

Worker ownership:

- Coordinator owns protected identity files, shared contracts, and final integration.
- Feature workers must stay inside their assigned directories.
- If a worker encounters concurrent changes outside its scope, it must adapt instead of reverting.
- Build workers may extend scripts, docs, and workflows, but they must preserve the one-target iPhone identity contract end to end.
