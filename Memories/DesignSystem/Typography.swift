import SwiftUI

/// Two roles, strictly separated.
///
/// The *editorial* voice — memory titles, section headlines, the date that opens the feed —
/// is the one the user chooses between: SF Pro, so the app reads as part of iOS, or New York
/// (`.serif`), so it reads as a personal magazine. The *functional* voice — controls, counts,
/// metadata, settings — is SF Pro under either choice. They never mix inside a single line.
///
/// The editorial constants are computed `static var`s that read `TypographyPreference`, and
/// that shape is the whole point. Two things had to hold at once: `Typo.memoryTitle` and the
/// rest are written the same way in dozens of views and could not change, and the switch had
/// to take effect while the user is looking at it. Reading `UserDefaults` here on each access
/// would satisfy the first and give the right *value*, but nothing would ask SwiftUI to run
/// those bodies again — almost none of the views that set editorial type ever touch
/// `AppSettings`, so they would keep their old fonts until relaunch. Reading an `@Observable`
/// property does both: the read happens inside the calling view's body, which registers that
/// body as an observer of the choice, so changing the picker invalidates exactly the views
/// that use editorial type and nothing else.
enum Typo {
    // Editorial — SF Pro or New York, per `AppSettings.typography`
    static func hero(_ size: CGFloat = 34) -> Font { editorial(size, .semibold) }
    static var memoryTitle: Font  { editorial(28, .semibold) }
    static var sectionTitle: Font { editorial(22, .semibold) }
    static var dateHeadline: Font { editorial(26, .regular) }
    static var quiet: Font        { editorial(17, .regular) }

    // Functional — SF Pro
    static let control       = Font.system(size: 16, weight: .medium)
    static let label         = Font.system(size: 15, weight: .regular)
    static let meta          = Font.system(size: 13, weight: .regular)
    static let overline      = Font.system(size: 12, weight: .semibold)
    static let tabLabel      = Font.system(size: 11, weight: .medium)

    private static func editorial(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: TypographyPreference.shared.style.design)
    }
}

extension View {
    /// Small uppercase overline used above section headlines.
    func overlineStyle() -> some View {
        self.font(Typo.overline)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(Palette.textTertiary)
    }
}

/// The spacing scale. Anything not on this scale is a mistake, not a decision.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let gutter: CGFloat = 20
    static let xl: CGFloat = 28
    static let section: CGFloat = 40
}

/// Corner radii, fixed per surface kind so related elements stay visually related.
enum Radius {
    static let hero: CGFloat = 28
    static let card: CGFloat = 22
    static let tile: CGFloat = 14
    static let thumb: CGFloat = 10
}
