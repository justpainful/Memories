import SwiftUI

/// Colour is deliberately scarce in this app: the photographs carry it, the chrome stays
/// near-neutral and slightly warm so images read like prints on paper rather than tiles on
/// a screen. Everything here is defined in both appearances so nothing has to be guessed
/// at call sites.
enum Palette {
    static let canvas       = Color(light: 0xFAF8F6, dark: 0x0C0B0A)
    static let surface      = Color(light: 0xFFFFFF, dark: 0x161514)
    static let surfaceSunk  = Color(light: 0xF1EDE8, dark: 0x1E1C1A)

    static let textPrimary  = Color(light: 0x12100E, dark: 0xF4F1ED)
    static let textSecondary = Color(light: 0x12100E, dark: 0xF4F1ED).opacity(0.55)
    static let textTertiary = Color(light: 0x12100E, dark: 0xF4F1ED).opacity(0.35)

    /// "Ember" — the single accent. Used for selection and emphasis, never as a background wash.
    static let accent       = Color(light: 0xB65B2E, dark: 0xE8894F)

    static let hairline     = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.09)

    /// Scrim over photography so overlaid type stays legible without dimming the image.
    static let photoScrim   = Color.black.opacity(0.34)
}

extension Color {
    /// Dynamic colour from two hex literals, resolved by the trait environment.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
