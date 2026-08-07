import SwiftUI

/// Three quiet lines and one button.
///
/// The first screen is a promise, so it says what the app will and will not do in plain
/// words, and then gets out of the way. No illustrations of clouds or robots, no carousel.
struct OnboardingView: View {
    @Environment(\.app) private var app
    @State private var isRequesting = false
    @State private var showDeniedHelp = false

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: Space.section)

                Text("Your photos.\nRemembered privately.")
                    .font(.system(size: 36, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.xl) {
                    promise("iphone", "Your library stays on this iPhone.")
                    promise("wand.and.sparkles", "Memories analyzes photos locally.")
                    promise("lock.slash", "Nothing is uploaded.")
                }
                .padding(.top, Space.section + Space.s)

                Spacer()

                VStack(spacing: Space.m) {
                    Button {
                        Task { await requestAccess() }
                    } label: {
                        Text(isRequesting ? "Requesting…" : "Allow Photo Access")
                            .font(.system(size: 17, weight: .semibold))
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
                .padding(.bottom, Space.section)
            }
            .padding(.horizontal, Space.xl)
        }
        .alert("Memories needs your photo library", isPresented: $showDeniedHelp) {
            Button("Open Settings") { openSettings() }
            Button("Not now", role: .cancel) { app.hasSeenOnboarding = true }
        } message: {
            Text("Without access there is nothing to remember. You can grant Full or Limited access in Settings, and change it at any time.")
        }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 26, alignment: .leading)
            Text(text)
                .font(Typo.quiet)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
