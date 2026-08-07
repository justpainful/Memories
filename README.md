# Memories

A standalone iPhone app that reads your photo library **on this device**, understands it, and
turns it into a daily-changing personal magazine of memories.

> Remember · Explore · Rediscover

Not another photo grid. Its one idea is that **time is the interface**: you move through your
library by *when*, and the app does the work of deciding what was worth remembering.

## Non-negotiables

| | |
|---|---|
| Native SwiftUI | iOS 26+ |
| Runs entirely on device | no backend, no accounts, no sign-in |
| Nothing is uploaded | no cloud processing, no AI API, no external analytics |
| Analysis | Apple frameworks only — Photos, Vision, SwiftData |
| Photo access | Full **and** Limited both fully supported |
| iCloud originals | never downloaded during indexing (`isNetworkAccessAllowed = false`) |
| Glass | real Liquid Glass only — `glassEffect`, `GlassEffectContainer`, `glassEffectID` |

The app never copies your library. It stores identifiers and computed metadata; the originals
stay in Photos.

## Layout

```
Memories.xcodeproj        hand-authored, objectVersion 77 with a synchronized root group,
                          so new Swift files need no project edits
Memories/                 app sources (this whole folder is the synchronized group)
  App/                    entry point and root navigation
  DesignSystem/           palette, typography, glass primitives, layout scale
Support/Info.plist        deliberately explicit — see the UILaunchScreen note inside
Scripts/                  app icon renderer, simulator seed-library generator
Docs/                     the goal spec, its checklist, and the design brief
.github/workflows/        build lane + UI smoke lane
```

## Building

Requires Xcode 26 (iOS 26 SDK). Open `Memories.xcodeproj` and run on an iPhone simulator or device.

Development happens on a machine without Xcode, so both compilation and visual checks run in CI:

- **Build** — `xcodebuild` against the iOS Simulator SDK; the compile-error feedback loop.
- **UI Smoke** — boots a simulator, seeds it with a synthetic photo library via `simctl addmedia`,
  grants Photos access, launches the app, captures screenshots and fails on any crash report.
  Screenshots are uploaded as artifacts so the UI is *looked at*, not assumed.

Regenerate the app icon after editing the renderer:

```bash
python Scripts/make_app_icon.py
```

## Privacy

There is no network code in this app. Nothing leaves the device — that is a property of the
architecture, not a promise in a settings screen. The in-app Privacy dashboard reports real
counters, including `Uploaded: 0`.
