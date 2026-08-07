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

extension View {
    /// A tappable control: chips, floating buttons, segmented items.
    func glassControl(_ shape: GlassShape = .capsule, tinted: Bool = false) -> some View {
        modifier(GlassControlModifier(shape: shape, tinted: tinted))
    }

    /// A transient surface that holds controls — the Explore Time panel, an action cluster.
    /// Not interactive itself; the things inside it are.
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

private struct GlassControlModifier: ViewModifier {
    let shape: GlassShape
    let tinted: Bool

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            content.glassEffect(glass, in: .capsule)
        case .rounded(let radius):
            content.glassEffect(glass, in: .rect(cornerRadius: radius))
        case .circle:
            content.glassEffect(glass, in: .circle)
        }
    }

    private var glass: Glass {
        tinted ? .regular.tint(Palette.accent).interactive() : .regular.interactive()
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(Typo.control)
            }
            .foregroundStyle(isSelected ? Color.white : Palette.textPrimary)
            .padding(.horizontal, Space.l)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassControl(.capsule, tinted: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A round icon button for floating clusters — viewer controls, the Explore Time trigger.
struct GlassIconButton: View {
    let systemImage: String
    var label: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Palette.textPrimary)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .glassControl(.circle, tinted: prominent)
        .accessibilityLabel(label)
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
