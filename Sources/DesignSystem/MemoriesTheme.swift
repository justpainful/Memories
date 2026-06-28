import SwiftUI

struct AppTheme: Sendable {
    let kind: ThemeKind
    let name: String
    let summary: String
    let accent: Color
    let secondaryAccent: Color
    let glassTint: Color
    let backgroundTop: Color
    let backgroundBottom: Color
    let halo: Color
    let cardFill: Color
    let cardStroke: Color
    let primaryText: Color
    let secondaryText: Color
}

enum AppThemes {
    static let nightSky = AppTheme(
        kind: .nightSky,
        name: "Night Sky",
        summary: "Midnight blue depth with a brighter celestial glow.",
        accent: Color(red: 0.48, green: 0.70, blue: 1.00),
        secondaryAccent: Color(red: 0.63, green: 0.49, blue: 0.96),
        glassTint: Color(red: 0.42, green: 0.60, blue: 0.94),
        backgroundTop: Color(red: 0.03, green: 0.06, blue: 0.14),
        backgroundBottom: Color(red: 0.08, green: 0.12, blue: 0.24),
        halo: Color(red: 0.69, green: 0.84, blue: 1.00).opacity(0.46),
        cardFill: Color.white.opacity(0.10),
        cardStroke: Color.white.opacity(0.18),
        primaryText: Color.white,
        secondaryText: Color.white.opacity(0.72)
    )

    static let reflectiveDark = AppTheme(
        kind: .reflectiveDark,
        name: "Reflective Dark",
        summary: "Smoked graphite with restrained silver reflections.",
        accent: Color(red: 0.84, green: 0.88, blue: 0.95),
        secondaryAccent: Color(red: 0.53, green: 0.72, blue: 0.92),
        glassTint: Color(red: 0.70, green: 0.78, blue: 0.92),
        backgroundTop: Color(red: 0.05, green: 0.05, blue: 0.07),
        backgroundBottom: Color(red: 0.12, green: 0.12, blue: 0.15),
        halo: Color(red: 0.95, green: 0.96, blue: 1.00).opacity(0.22),
        cardFill: Color.white.opacity(0.08),
        cardStroke: Color.white.opacity(0.14),
        primaryText: Color.white,
        secondaryText: Color.white.opacity(0.70)
    )

    static func definition(for kind: ThemeKind) -> AppTheme {
        switch kind {
        case .nightSky:
            nightSky
        case .reflectiveDark:
            reflectiveDark
        }
    }

    static let all = ThemeKind.allCases.map(definition(for:))
}

extension ThemeKind {
    var displayName: String {
        AppThemes.definition(for: self).name
    }

    var onboardingSummary: String {
        AppThemes.definition(for: self).summary
    }
}

private struct MemoriesThemeKey: EnvironmentKey {
    static let defaultValue = AppThemes.nightSky
}

extension EnvironmentValues {
    var memoriesTheme: AppTheme {
        get { self[MemoriesThemeKey.self] }
        set { self[MemoriesThemeKey.self] = newValue }
    }
}

extension View {
    func appTheme(_ theme: AppTheme) -> some View {
        environment(\.memoriesTheme, theme)
    }
}

struct AppBackgroundView: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backgroundTop, theme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(theme.halo)
                .frame(width: 300, height: 300)
                .blur(radius: 26)
                .offset(x: -110, y: -230)

            Circle()
                .fill(theme.secondaryAccent.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 30)
                .offset(x: 150, y: 220)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.clear,
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.softLight)
        }
        .ignoresSafeArea()
    }
}

typealias MemoriesThemeDefinition = AppTheme
typealias MemoriesThemes = AppThemes
typealias MemoriesBackgroundView = AppBackgroundView
