import SwiftUI

/// The app's Liquid Glass vocabulary.
///
/// Two rules govern every use of glass here, and they are the reason this file exists rather
/// than each view reaching for `.glassEffect` on its own:
///
/// 1. **Glass is the control layer.** Navigation, chips, floating controls, toolbars, menus
///    and transient panels are glass. Content — photographs, cards, list rows, the feed
///    itself — is never glass. If a screen looks mostly like glass, it is wrong.
/// 2. **Only the real thing.** `.glassEffect`, `GlassEffectContainer` and `glassEffectID`.
///    No `.ultraThinMaterial`, no `.blur`, no translucent rectangle pretending to be glass.
///
/// The deployment target is iOS 26, so none of this needs availability gating or a fallback.
enum GlassShape {
    case capsule
    case rounded(CGFloat)
    case circle
}

/// Which of the two real Liquid Glass materials a control should use.
///
/// `regular` is the load-bearing one: it adapts to whatever is behind it and keeps text
/// legible over unpredictable content, which is what a tab bar sitting over a scrolling
/// feed needs.
///
/// `clear` is far more transparent and does much less to the content behind it, so the
/// material's actual behaviour — the way it bends light at its edges and shifts as the
/// device moves — is visible rather than muted. It is meant for controls floating over
/// media, where the photograph should stay the brightest thing on screen. That is exactly
/// the viewer, so the viewer uses it; it would be the wrong choice over a white list.
enum GlassTone {
    case regular
    case clear

    /// What this tone draws as when the reader has asked iOS to stop making things
    /// see-through.
    ///
    /// Reduce Transparency is not a request for a weaker blur — it is a request for a *surface*,
    /// because a control you can see the wallpaper through is a control some people cannot find
    /// the edges of. So the fallback is opaque, and it is opaque with a system colour rather
    /// than with a material, which would be the same failure by another name.
    ///
    /// The two tones fall back differently because they sit over different things. `regular`
    /// lives over the app's own canvas, so it becomes the canvas. `clear` lives over a
    /// photograph in a black full-screen viewer whose glyphs are all white, so it becomes
    /// black; handing it `systemBackground` would put a white slab over the picture in light
    /// mode and white glyphs on it.
    var opaqueFallback: Color {
        switch self {
        case .regular: return Palette.canvas
        case .clear:   return .black
        }
    }

    /// The edge that fallback needs to be a shape rather than a smear.
    var opaqueEdge: Color {
        switch self {
        case .regular: return Palette.hairline
        case .clear:   return .white.opacity(0.28)
        }
    }

    /// The material this tone actually draws with.
    ///
    /// Clear is handed a low black tint rather than used bare. Clear makes no promise about
    /// legibility — that is precisely the trade it offers, and the reason it is confined to
    /// controls over media — so the moment the photograph underneath is a bright one, the
    /// white glyphs and captions drawn on it have nothing left to stand against. A snowfield,
    /// a white wall or a blown-out sky is not an edge case in a photo viewer; it is Tuesday.
    /// The tint is a fraction of what the regular material does, so the picture is still the
    /// brightest thing on screen, which was the whole reason clear was chosen there.
    var material: Glass {
        switch self {
        case .regular: return Glass.regular
        case .clear:   return Glass.clear.tint(Color.black.opacity(0.22))
        }
    }
}

extension View {
    /// A tappable control: chips, floating buttons, segmented items.
    func glassControl(_ shape: GlassShape = .capsule,
                      tone: GlassTone = .regular,
                      tinted: Bool = false) -> some View {
        modifier(GlassControlModifier(shape: shape, tone: tone, tinted: tinted))
    }

    /// A transient surface that holds controls — the Explore Time panel, an action cluster.
    /// Not interactive itself; the things inside it are.
    func glassPanel(cornerRadius: CGFloat = Radius.hero, tone: GlassTone = .regular) -> some View {
        modifier(GlassControlModifier(shape: .rounded(cornerRadius), tone: tone,
                                      tinted: false, interactive: false))
    }
}

private struct GlassControlModifier: ViewModifier {
    let shape: GlassShape
    let tone: GlassTone
    let tinted: Bool
    var interactive: Bool = true

    /// The one setting glass has to answer. Everything else about the material adapts on its
    /// own; this is the reader saying they do not want the material at all.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            switch shape {
            case .capsule:            opaque(content, in: .capsule)
            case .rounded(let radius): opaque(content, in: .rect(cornerRadius: radius))
            case .circle:             opaque(content, in: .circle)
            }
        } else {
            switch shape {
            case .capsule:            content.glassEffect(glass, in: .capsule)
            case .rounded(let radius): content.glassEffect(glass, in: .rect(cornerRadius: radius))
            case .circle:             content.glassEffect(glass, in: .circle)
            }
        }
    }

    /// A solid control, shaped exactly like the glass one it stands in for.
    ///
    /// The stroke matters as much as the fill: without an edge, an opaque capsule the colour of
    /// the background it sits on is invisible, which is the opposite of what the setting asked
    /// for.
    private func opaque<S: InsettableShape>(_ content: Content, in shape: S) -> some View {
        content
            .background(tinted ? Palette.accent : tone.opaqueFallback, in: shape)
            .overlay(shape.strokeBorder(tone.opaqueEdge, lineWidth: 1))
    }

    /// A tinted control names its own colour, so it replaces the tone's tint rather than
    /// adding to it: a selected chip should read as the system accent, not as the accent seen
    /// through a dark pane.
    private var glass: Glass {
        let base = tinted ? tone.material.tint(Palette.accent) : tone.material
        return interactive ? base.interactive() : base
    }
}

// MARK: - Components

/// A filter chip. Used in rows inside a `GlassEffectContainer` so neighbouring chips
/// blend into one another instead of reading as separate blobs.
struct GlassChip: View {
    let title: String
    var systemImage: String?
    var isSelected: Bool = false
    let action: () -> Void

    /// Selection is drawn in colour, and colour is the one channel some readers do not have.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let systemImage {
                    Image(systemName: systemImage).font(Typo.glyph(13))
                }
                // A selected chip is a filled accent capsule and an unselected one is clear
                // glass, which is the whole of the difference — so with Differentiate Without
                // Color on, the selected one also carries a tick. It goes after the label
                // rather than before it, where it reads as a state rather than as an icon.
                Text(title).font(Typo.control)
                if isSelected && differentiateWithoutColor {
                    Image(systemName: "checkmark").font(Typo.glyph(12, .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Palette.textPrimary)
            .padding(.horizontal, Space.l)
            // A sixteen-point label with ten points above and below came out at forty, four
            // short of the smallest target Apple will vouch for — and these are among the most
            // tapped controls in the app. The floor is stated rather than padded up to, so it
            // still holds if the label ever grows.
            .frame(minHeight: Hit.min)
            // Without this only the text and the glyph answer a finger. The padding around
            // them is most of the capsule, and it was dead.
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassControl(.capsule, tinted: isSelected)
        // The symbol beside the label is decoration; without this VoiceOver reads its SF
        // Symbol name — "line 3 horizontal decrease circle" — before the word the chip is for.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A round icon button for floating clusters — viewer controls, the Explore Time trigger.
struct GlassIconButton: View {
    let systemImage: String
    var label: String
    var prominent: Bool = false
    var tone: GlassTone = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typo.glyph(17))
                // Over a photograph the glass is clear, so the symbol carries its own
                // contrast rather than relying on the material to provide it. The shadow is
                // tight and dark rather than wide and faint: it has to draw an edge around a
                // white glyph lying on a white photograph, and a soft halo at a quarter black
                // only greys the picture without ever reaching that.
                .foregroundStyle(prominent || tone == .clear ? Color.white : Palette.textPrimary)
                .shadow(color: .black.opacity(tone == .clear ? 0.4 : 0), radius: 2, y: 1)
                .frame(width: 46, height: 46)
                // Forty-six points of glass around a seventeen-point glyph, and only the glyph
                // was answering: `frame` gives a view its size, never its touch area. The
                // button measured forty-six and behaved like seventeen.
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassControl(.circle, tone: tone, tinted: prominent)
        // The glyph is the whole of the label, so it is replaced rather than described: without
        // `.ignore`, VoiceOver reads the SF Symbol's name after the label it was given.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

/// Divider used *inside* a glass panel. A hairline, never a heavy rule.
struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, Space.l)
    }
}
