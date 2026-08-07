import SwiftUI

/// Two families, strictly separated.
///
/// New York (`.serif`) is the *editorial* voice — memory titles, section headlines, the date
/// that opens the feed. It is what makes the app read as a personal magazine instead of a
/// file browser. SF Pro is the *functional* voice — controls, counts, metadata, settings.
/// They never mix inside a single line.
enum Typo {
    // Editorial — New York
    static func hero(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let memoryTitle   = Font.system(size: 28, weight: .semibold, design: .serif)
    static let sectionTitle  = Font.system(size: 22, weight: .semibold, design: .serif)
    static let dateHeadline  = Font.system(size: 26, weight: .regular, design: .serif)
    static let quiet         = Font.system(size: 17, weight: .regular, design: .serif)

    // Functional — SF Pro
    static let control       = Font.system(size: 16, weight: .medium)
    static let label         = Font.system(size: 15, weight: .regular)
    static let meta          = Font.system(size: 13, weight: .regular)
    static let overline      = Font.system(size: 12, weight: .semibold)
    static let tabLabel      = Font.system(size: 11, weight: .medium)
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
