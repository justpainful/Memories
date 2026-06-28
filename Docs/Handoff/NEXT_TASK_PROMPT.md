# Next Task Prompt

Continue Phase 2 for the `Memories` iPhone app in `C:\Users\kuroi\OneDrive\Desktop\Memories`.

Current repository state:

- XcodeGen, identity lock, CI, and unsigned IPA workflows already exist.
- The app shell, onboarding, feed, local persistence, curation engine, sharing path, and the three non-feed tabs are already implemented.
- The canonical brand asset is still missing at `Design/Brand/memories-logo-reference.png`, so AppIcon generation remains blocked.
- This Windows host still cannot run `swift`, `xcodegen`, `bash`, or `xcodebuild`, so macOS CI is the real build verifier.

Your Phase 2 goals:

1. Validate the existing project on macOS by running XcodeGen, building, and fixing compile drift until CI is green.
2. Implement a real `VisionAestheticRanker` behind the existing curation scoring seam and benchmark it against the current deterministic scorer.
3. Replace the simple event/burst grouping with stronger event clustering and duplicate suppression.
4. Expand integration and restoration tests for asset deletion, return from Recently Deleted, and ambiguous recovery cases.
5. Add performance instrumentation for large libraries and feed preloading.
6. If and only if the brand asset is now present, generate the AppIcon source and wire it into the asset catalog without changing the brand direction.

Do not redo Phase 1 scaffolding. Preserve the immutable bundle identifier `space.hi.memories`, keep a single iPhone target only, and keep the app local-first.

