import SwiftUI

/// Two roles, strictly separated.
///
/// The *editorial* voice — memory titles, section headlines, the date that opens the feed —
/// is the one the user chooses between: SF Pro, so the app reads as part of iOS, or New York
/// (`.serif`), so it reads as a personal magazine. The *functional* voice — controls, counts,
/// metadata, settings — is SF Pro under either choice. They never mix inside a single line.
///
/// **Every font here is a text style, and that is the point.** It used to be
/// `.system(size:weight:)` throughout, which is a fixed number of points and answers nothing:
/// the whole app rendered at the same size whether the reader had left Dynamic Type alone or
/// pushed it to the largest accessibility setting. For an app whose entire content is
/// photographs with captions, that is not a rough edge, it is a wall.
///
/// The sizes were already Apple's own scale — 34, 28, 22, 17, 16, 15, 13, 12, 11 — so each one
/// maps onto the matching text style exactly, and SwiftUI does the scaling itself, live, with
/// no font metrics arithmetic to get wrong. One size moved: the feed's date headline was 26,
/// which is not a rung, and it now sits on `.title` at 28.
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
    static var dateHeadline: Font { editorial(28, .regular) }
    static var quiet: Font        { editorial(17, .regular) }

    // Functional — SF Pro
    static let control       = Font.callout.weight(.medium)      // 16
    static let label         = Font.subheadline                  // 15
    static let meta          = Font.footnote                     // 13
    static let overline      = Font.caption.weight(.semibold)    // 12
    static let tabLabel      = Font.caption2.weight(.medium)     // 11

    /// An editorial font at a size the constants above do not cover.
    ///
    /// Public because several screens set a one-off headline size. They must come through
    /// here rather than writing `design: .serif` themselves — a hard-coded serif ignores the
    /// user's choice, and the result is a Settings switch that changes some of the text on a
    /// screen and not the rest.
    static func editorial(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(style(nearest: size), design: TypographyPreference.shared.style.design)
            .weight(weight)
    }

    /// SF Pro at a one-off size, scaled.
    ///
    /// The replacement for every `.font(.system(size: N, weight: W))` that used to be written
    /// inline. It takes the same number the call site already had and lands it on the rung of
    /// Apple's scale that number was reaching for, so the text now grows with the reader
    /// without any screen being redesigned around a new size.
    static func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(style(nearest: size)).weight(weight)
    }

    /// A symbol drawn inside a control whose size is fixed by its own geometry — the 46-point
    /// round glass buttons, a badge in the corner of a thumbnail, the chevron in a chip.
    ///
    /// These deliberately do *not* scale. A glyph that grows past the circle it is centred in
    /// does not become more legible, it becomes clipped, and the control around it cannot grow
    /// because its size is what makes the cluster line up. Apple's own toolbars behave the same
    /// way. Everything a symbol is standing in for is carried by the button's accessibility
    /// label, which is where a reader who needs larger text is actually being served.
    static func glyph(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// The rung of Apple's type scale nearest a point size.
    ///
    /// Nearest rather than next-largest: the sizes this app was written with are already on
    /// the scale, so almost every one of them lands exactly, and the handful that do not are
    /// better served by the closest rung than by always rounding one way.
    private static func style(nearest size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5:  return .caption2      // 11
        case ..<12.5:  return .caption       // 12
        case ..<14:    return .footnote      // 13
        case ..<15.5:  return .subheadline   // 15
        case ..<16.5:  return .callout       // 16
        case ..<18.5:  return .body          // 17
        case ..<21:    return .title3        // 20
        case ..<25:    return .title2        // 22
        case ..<31:    return .title         // 28
        default:       return .largeTitle    // 34
        }
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

    /// A ceiling on how far text inside a piece of fixed chrome is allowed to grow.
    ///
    /// Used only where the container genuinely cannot grow with it — a tab bar pinned to the
    /// bottom of the screen, a badge inside a thumbnail, a day cell in a calendar month. The
    /// content of the app is never capped; only the furniture around it is, and it is capped at
    /// `accessibility1` rather than at the default size, so it still answers the setting.
    ///
    /// Anywhere the layout *can* grow, it should — a cap is an admission, not a strategy.
    func chromeTypeSize(_ ceiling: DynamicTypeSize = .accessibility1) -> some View {
        self.dynamicTypeSize(...ceiling)
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
///
/// Nesting rule: a radius drawn inside another should be the outer one less the padding
/// between them, or smaller. Going the other way — a tight outer corner around a rounder
/// inner one — is what makes a panel look like it is squeezing its contents.
enum Radius {
    static let hero: CGFloat = 28
    static let card: CGFloat = 22

    /// A small floating glass panel: a confirmation caption, the year scrubber, a batch-action
    /// cluster. Chrome laid over content rather than content itself, so it is tighter than a
    /// card and never as open as a hero.
    static let panel: CGFloat = 18

    static let tile: CGFloat = 14
    static let thumb: CGFloat = 10

    /// One photograph in a dense grid. Nearly square on purpose — at seven across anything
    /// rounder stops reading as photographs and starts reading as a sheet of lozenges.
    static let gridTile: CGFloat = 6
}

/// The smallest square iOS will vouch for as something a finger can reliably hit.
///
/// Named rather than written as `44` at each call site, because the number is a rule from the
/// Human Interface Guidelines and a reader coming across a bare `44` cannot tell whether it is
/// that rule or a coincidence.
enum Hit {
    static let min: CGFloat = 44
}
