import SwiftUI

/// The app's mark, drawn rather than loaded.
///
/// The same glyph as the icon — two prints offset along the diagonal, the one in front carrying
/// a hill and a sun — built from the same proportions as `Scripts/make_app_icon.py` so the two
/// cannot drift apart. It is shapes rather than an image because the one place it appears is a
/// navigation bar: it has to be crisp at every scale factor and it has to follow the label
/// colour in light and dark. A PNG does neither.
///
/// Monochrome on purpose. The icon's gradient belongs on the Home Screen; up here the mark is a
/// piece of type, and everything else in a navigation bar is drawn in the label colour.
///
/// Fixed size, for the reason `Typo.glyph` is fixed: the bar cannot get taller, so a mark that
/// grew with the reader's text size would be a mark clipped by its own bar. Nothing is lost —
/// the screen's name is still set on every one of them, which is what VoiceOver reads.
struct MemoriesMark: View {
    var side: CGFloat = 28

    // Proportions of the box, lifted from the icon renderer.
    private var card: CGFloat { side * 0.455 }
    private var radius: CGFloat { side * 0.108 }
    private var offset: CGFloat { side * 0.082 }
    private var gap: CGFloat { side * 0.030 }
    private var inset: CGFloat { card * 0.085 }

    var body: some View {
        ZStack {
            backPrint
            frontPrint.offset(x: offset, y: offset)
        }
        .frame(width: side, height: side)
        .foregroundStyle(Color.primary)
        .accessibilityHidden(true)
    }

    /// The print behind, with a hairline gap taken out of it where the front one overlaps.
    ///
    /// A knocked-out gap rather than a shadow or a stroke — that is how Apple's own icons
    /// separate two overlapping shapes, and it is the difference between a flat glyph and a
    /// little illustration of a stack of paper.
    private var backPrint: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .frame(width: card, height: card)
                .offset(x: -offset, y: -offset)
            RoundedRectangle(cornerRadius: radius + gap, style: .continuous)
                .frame(width: card + gap * 2, height: card + gap * 2)
                .offset(x: offset, y: offset)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    /// The print in front, with the photograph knocked out of it: a soft hill and a sun.
    /// Two shapes and no more — it still reads at the size a navigation bar gives it.
    private var frontPrint: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .frame(width: card, height: card)

            ZStack {
                Ellipse()
                    .frame(width: card * 1.48, height: card * 0.71)
                    .offset(x: -card * 0.12, y: card * 0.52)
                Circle()
                    .frame(width: card * 0.256, height: card * 0.256)
                    .offset(x: card * 0.235, y: -card * 0.215)
            }
            .frame(width: card, height: card)
            .clipShape(
                RoundedRectangle(cornerRadius: radius - inset * 0.75, style: .continuous)
                    .inset(by: inset)
            )
            .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

extension View {
    /// The navigation bar every tab root wears: the system bar, untouched, showing the app's
    /// mark instead of its name.
    ///
    /// *Untouched* is the operative word, and it is the whole of the logic borrowed here. iOS 26
    /// gives a navigation bar real Liquid Glass on its own — it refracts whatever scrolls under
    /// it and takes its colour from that — and every modifier reaching in to improve the bar's
    /// background takes some of it away. The feed and the Timeline both carried
    /// `.scrollEdgeEffectStyle(.soft)`, which is not a softer glass but the styleless substitute
    /// for it, and between them that is most of the time anyone spends in this app. Nothing here
    /// touches the bar's background, and nothing should.
    ///
    /// The title is still set. It is what the next screen's back button reads, what VoiceOver
    /// announces on arrival, and what the UI tour identifies a screen by; only the drawn text is
    /// replaced. Inline rather than large, because a large-title area holding a logo is a
    /// large-title area with a hole in it.
    func markedNavigationBar(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { MemoriesMark() }
            }
    }
}

#Preview {
    NavigationStack {
        ScrollView { Color.clear.frame(height: 2000) }
            .markedNavigationBar("Memories")
    }
}
