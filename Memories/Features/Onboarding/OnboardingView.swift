import SwiftUI

/// Three quiet lines and one button.
///
/// The first screen is a promise, so it says what the app will and will not do in plain
/// words, and then gets out of the way. No illustrations of clouds or robots, no carousel.
///
/// It is also the only door into the app, which is why the layout below is a `ScrollView` with
/// the button held in a bottom inset rather than the fixed column it used to be. A fixed column
/// is fine until the reader has asked for larger text: at the accessibility sizes the headline
/// alone is most of a phone screen, the `Spacer`s collapse to nothing, and the one control on
/// the screen is laid out below the bottom edge with no way to reach it. The app was then not
/// merely hard to read — it could not be entered at all. Everything that can grow now scrolls,
/// and the button never scrolls away.
struct OnboardingView: View {
    @Environment(\.app) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// The icon column has to widen with the type beside it. Frozen at 26 points, a 17-point
    /// symbol rendered at an accessibility size overhangs its slot on both sides and lands on
    /// the first word of the promise it is introducing.
    @ScaledMetric(relativeTo: .body) private var promiseIcon: CGFloat = 26

    @State private var isRequesting = false
    @State private var showDeniedHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // No hard line break. Where "Your photos." ends is a fact about the width of
                // one phone at one text size, and baking it into the string means the headline
                // breaks in the wrong place everywhere else.
                Text("Your photos. Remembered privately.")
                    .font(Typo.editorial(36))
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.xl) {
                    promise(DeviceName.current == "iPad" ? "ipad" : "iphone",
                            "Your library stays on \(DeviceName.thisDevice).")
                    promise("wand.and.sparkles", "Memories analyses photos locally.")
                    promise("lock.slash", "Nothing is uploaded.")
                }
                .padding(.top, Space.section + Space.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The padding the `Spacer`s used to stand in for. Stated rather than left over, so
            // the block reads the same whether there is room to spare or none at all.
            .padding(.top, Space.section)
            .padding(.bottom, Space.section)
            .padding(.horizontal, Space.xl)
            // A promise set across a landscape iPad is a line of text a foot wide.
            .readableMeasure()
        }
        // At the default sizes everything fits, and a screen that bounces when nothing can move
        // reads as a screen that is missing something below the fold.
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { actions }
        .alert("Memories needs your photo library", isPresented: $showDeniedHelp) {
            Button("Open Settings") { openSettings() }
            Button("Not now", role: .cancel) { app.hasSeenOnboarding = true }
        } message: {
            Text("Without access there is nothing to remember. You can grant Full or Limited access in Settings, and change it at any time.")
        }
        // Coming back from iOS Settings having granted access is indistinguishable from having
        // completed onboarding, and the app should behave as if it were. Without this the
        // reader is returned to this very screen — the promises and an "Allow Photo Access"
        // button — for a permission they have already given, and has to ask a second time.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            app.library.refreshAccess()
            guard app.library.access.canRead else { return }
            app.hasSeenOnboarding = true
            app.startIndexingIfPossible()
        }
    }

    /// The one control, and the line under it. Held out of the scroll view so that however far
    /// the text above grows, the way past this screen is always on it.
    private var actions: some View {
        VStack(spacing: Space.m) {
            Button {
                Task { await requestAccess() }
            } label: {
                Text(isRequesting ? "Requesting…" : "Allow Photo Access")
                    .font(Typo.scaled(17, .semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .disabled(isRequesting)

            Text("Memories never uploads, and works without an account.")
                .font(Typo.meta)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.m)
        .padding(.bottom, Space.gutter)
        .readableMeasure()
        // The inset sits over the canvas, and a button floating on a transparent strip with the
        // headline sliding underneath it is the one thing worse than a button that scrolls away.
        .background(Palette.canvas)
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            Image(systemName: symbol)
                .font(Typo.scaled(17, .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: promiseIcon, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.quiet)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // The symbol is decoration for a sentence that already says the whole thing. Left to
        // itself VoiceOver opens the app by reading out "iphone", "wand.and.sparkles" and
        // "lock.slash" ahead of the three promises, which is the app's first impression.
        .accessibilityElement(children: .combine)
    }

    private func requestAccess() async {
        isRequesting = true
        let access = await app.library.requestAccess()
        isRequesting = false

        switch access {
        case .full, .limited:
            app.hasSeenOnboarding = true
            app.startIndexingIfPossible()
        case .denied, .restricted:
            showDeniedHelp = true
        case .notDetermined:
            break
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    OnboardingView()
}
