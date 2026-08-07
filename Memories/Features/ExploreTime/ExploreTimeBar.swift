import SwiftUI

/// The app's signature control, and the reason the tab bar is drawn here rather than by
/// `TabView`.
///
/// The specification is explicit: pressing Explore should make *the toolbar's own glass*
/// become the time panel — one continuous piece of material that grew, not a sheet that
/// slid up over it. That is only possible if the bar and the panel are two states of the
/// same `glassEffectID` inside one `GlassEffectContainer`, which means owning the bar.
///
/// Everything here is the real API: `GlassEffectContainer`, `glassEffect`, `glassEffectID`.
struct ExploreTimeBar: View {
    @Binding var selection: AppTab
    @Binding var isExploring: Bool
    let onSelectWindow: (TimeWindow) -> Void

    /// How long the bar takes to become the time panel, and back.
    ///
    /// Declared once because more than one layer animates on it — the panel here, the dim
    /// behind it in `RootView` — and they have to arrive together. Anything that needs to wait
    /// for the morph to finish waits for this rather than guessing at a number.
    static let morphDuration = 0.42

    @Namespace private var glass

    var body: some View {
        // The container's spacing is the distance at which two pieces of glass start reaching
        // for each other, and it is deliberately *below* the gap between the bar and the
        // Explore button. At twenty-two against a gap of eighteen they were permanently joined
        // by a liquid bridge, so the bottom of every screen was one wide smear rather than two
        // controls. It has nothing to do with the morph: that is carried by `glassEffectID`,
        // which does not care how far apart the two states are.
        GlassEffectContainer(spacing: Space.m) {
            if isExploring {
                // The panel sits over dimmed content and holds a list, so it keeps the
                // regular material: clear glass here would make its rows hard to read.
                panel
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.hero))
                    .glassEffectID("bar", in: glass)
            } else {
                HStack(spacing: Space.l) {
                    // Regular, not clear. Clear glass was tried here and the screenshots
                    // settled it: the bar floats over a full-bleed photograph that can be any
                    // colour, and against a dark one the unselected labels became grey text
                    // on a dark picture. Regular adapts to what is behind it, which is the
                    // whole reason it exists. Clear belongs where the content is a photograph
                    // the user is deliberately looking at — the viewer — and the controls
                    // should get out of its way.
                    tabs
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("bar", in: glass)

                    exploreButton
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("explore", in: glass)
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.s)
        // `RootView` animates the same value on the layer above, for the dim behind this bar.
        // The innermost one wins inside its own subtree, so the two are not competing — but
        // they do have to stay the same curve and the same duration, or the panel and the dim
        // it sits on will arrive at different moments.
        .animation(.smooth(duration: Self.morphDuration), value: isExploring)
    }

    // MARK: Collapsed

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    selection = tab
                    Haptics.selection()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .symbolVariant(selection == tab ? .fill : .none)
                        Text(tab.title).font(Typo.tabLabel)
                    }
                    .foregroundStyle(selection == tab ? Palette.accent : Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    // Matches the selection pill the system bar draws, so replacing it
                    // does not read as a downgrade.
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(Palette.accent.opacity(0.14))
                                .matchedGeometryEffect(id: "tabPill", in: glass)
                        }
                    }
                    // Each tab claims a third of the bar, but only the glyph and its label
                    // answered a finger: `frame` gives a view its size, never its touch area,
                    // and the selection pill that would have carried one is drawn for the
                    // selected tab only. So taps a few points to either side of "Timeline" did
                    // nothing at all — which from the outside is a bar that sticks.
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, Space.s)
        .animation(.smooth(duration: 0.28), value: selection)
    }

    private var exploreButton: some View {
        Button {
            isExploring = true
            Haptics.impact()
        } label: {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 56, height: 56)
                // Fifty-six points of glass around an eighteen-point glyph, and only the glyph
                // was taking the touch. See `tabs`.
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Explore time")
    }

    // MARK: Expanded

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Explore Time")
                    .font(Typo.editorial(17))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button {
                    isExploring = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.l)
            .padding(.bottom, Space.m)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(TimeWindow.exploreGroups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { GlassDivider().padding(.vertical, Space.s) }
                        ForEach(group) { window in
                            Button {
                                // Ahead of the state changes rather than after them, so the
                                // tap is felt when the finger lands instead of once the panel
                                // has already started folding away.
                                Haptics.impact()
                                isExploring = false
                                onSelectWindow(window)
                            } label: {
                                HStack {
                                    Text(window.title)
                                        .font(Typo.control)
                                        .foregroundStyle(Palette.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                                .padding(.horizontal, Space.l)
                                // Eleven points above and below a sixteen-point line is a
                                // forty-two point row, and every row in this panel is a
                                // destination. Two short is still short.
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, Space.l)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 380)
        }
    }
}

/// Small, consistent haptics. Selection for switching, impact for opening something.
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .soft) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
