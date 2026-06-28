# Decision Log

## Phase 1

### 2026-06-28

1. XcodeGen is required so the app can be regenerated without opening Xcode manually.
2. The bundle identity is locked in `Config/AppIdentity.xcconfig` and must flow through build settings and `Info.plist`.
3. The repository contains one iPhone application target plus the standard unit-test and UI-test bundles only.
4. Media remains in Apple Photos. The app persists only references and local metadata.
5. Liquid Glass adoption is native-first and gated to iOS 26 APIs, with fallbacks only as compile-time compatibility helpers where necessary.
6. GitHub Actions on macOS are the real iOS build and IPA verification path from this Windows host.

