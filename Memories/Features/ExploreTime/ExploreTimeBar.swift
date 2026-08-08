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

    /// The height of the window this bar is floating at the bottom of. The panel is sized
    /// against it rather than against a number, because a fixed 380-point list is taller than
    /// the whole screen of an iPhone lying on its side.
    var availableHeight: CGFloat = 800

    /// Written back with what this bar actually came out at, so every scrolling screen in the
    /// app can end above it instead of above a number someone measured once.
    @Binding var measuredHeight: CGFloat

    @Namespace private var glass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The morph, or a cross-dissolve where the reader has asked for less movement.
    ///
    /// This is the app's signature transition, and it is the first thing to go: the bar does not
    /// merely fade into the panel, it grows out of it across most of the screen. Reduce Motion
    /// exists for exactly that. The two states still swap, and they still swap on the same
    /// timing so nothing else in the shell arrives out of step — they just stop travelling.
    private var morph: Animation? {
        reduceMotion ? .easeInOut(duration: Self.morphDuration) : .smooth(duration: Self.morphDuration)
    }

    /// The widest this bar is allowed to get.
    ///
    /// Three tabs and a button stretched across a landscape iPad is not a tab bar, it is a
    /// horizon with four things on it. Apple's own floating bars stay compact and centred in a
    /// wide window, and so does this one — the number is the point at which the tabs stop
    /// getting further apart and start staying put.
    private static let widthCap: CGFloat = 520

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
                surface(panel, shape: .rounded(Radius.hero), interactive: false)
                    // The panel covers the app and dims everything under it, so it has to say
                    // so. Without `.isModal`, VoiceOver goes on swiping into the feed behind
                    // it — a reader ends up somewhere they cannot see is still there, with no
                    // sense that anything is open or how to close it.
                    .accessibilityAddTraits(.isModal)
                    // Under Reduce Motion the two states stop being one travelling piece of
                    // glass and become two that cross-fade, which is what dropping the shared
                    // identity does. Keeping the identity and merely slowing the curve would
                    // still send the bar sliding up the screen.
                    .glassEffectID(reduceMotion ? "panel" : "bar", in: glass)
                    .transition(.opacity)
            } else {
                HStack(spacing: Space.l) {
                    // Regular, not clear. Clear glass was tried here and the screenshots
                    // settled it: the bar floats over a full-bleed photograph that can be any
                    // colour, and against a dark one the unselected labels became grey text
                    // on a dark picture. Regular adapts to what is behind it, which is the
                    // whole reason it exists. Clear belongs where the content is a photograph
                    // the user is deliberately looking at — the viewer — and the controls
                    // should get out of its way.
                    surface(tabs, shape: .capsule)
                        .glassEffectID("bar", in: glass)

                    surface(exploreButton, shape: .circle)
                        .glassEffectID("explore", in: glass)
                }
                .transition(.opacity)
            }
        }
        // Centred and capped rather than stretched. `frame(maxWidth:)` on its own would also
        // stop the bar shrinking on a narrow window, so the cap and the centring are two frames.
        .frame(maxWidth: Self.widthCap)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.s)
        // What every scrolling screen in the app ends above. Measured rather than assumed: the
        // bar grows with the reader's text size and with the home indicator, and a screen that
        // insets by a remembered number puts its last row underneath it.
        //
        // Only measured while collapsed. Expanded it is the Explore Time panel, which is most
        // of the screen tall, and inseting every feed by that would leave a hole at the bottom
        // of the app for as long as the panel is open.
        .measuringBarHeight(isExploring ? .constant(0) : $measuredHeight)
        // `RootView` animates the same value on the layer above, for the dim behind this bar.
        // The innermost one wins inside its own subtree, so the two are not competing — but
        // they do have to stay the same curve and the same duration, or the panel and the dim
        // it sits on will arrive at different moments.
        .animation(morph, value: isExploring)
    }

    /// The bar's glass, or the solid control it becomes when the reader has turned transparency
    /// off.
    ///
    /// Written out here rather than routed through `glassControl` because these three surfaces
    /// carry a `glassEffectID`, and that identifier has to land on the same view the material
    /// does for the morph between the bar and the panel to happen at all.
    @ViewBuilder
    private func surface<V: View>(_ content: V, shape: GlassShape, interactive: Bool = true) -> some View {
        if reduceTransparency {
            switch shape {
            case .capsule:             solid(content, in: Capsule())
            case .circle:              solid(content, in: Circle())
            case .rounded(let radius): solid(content, in: RoundedRectangle(cornerRadius: radius,
                                                                          style: .continuous))
            }
        } else {
            let material: Glass = interactive ? .regular.interactive() : .regular
            switch shape {
            case .capsule:             content.glassEffect(material, in: .capsule)
            case .circle:              content.glassEffect(material, in: .circle)
            case .rounded(let radius): content.glassEffect(material, in: .rect(cornerRadius: radius))
            }
        }
    }

    private func solid<V: View, S: InsettableShape>(_ content: V, in shape: S) -> some View {
        content
            .background(Palette.canvas, in: shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
    }

    // MARK: Collapsed

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    guard selection != tab else { return }
                    selection = tab
                    Haptics.selection()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(Typo.glyph(17, .medium))
                            .symbolVariant(selection == tab ? .fill : .none)
                        Text(tab.title)
                            .font(Typo.tabLabel)
                            // A tab title is a single word in a bar that cannot get taller
                            // without eating the screen, so it is allowed to grow and then
                            // hold. It never truncates: a shrunk-to-fit label still reads,
                            // a clipped one does not.
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(selection == tab ? Palette.accent : Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Hit.min)
                    .padding(.vertical, 10)
                    // Matches the selection pill the system bar draws, so replacing it
                    // does not read as a downgrade.
                    .background {
                        if selection == tab {
                            // The pill slides from the old tab to the new one, which is the
                            // system bar's own behaviour — except under Reduce Motion, where
                            // dropping the shared geometry makes it appear where it belongs
                            // instead of travelling there.
                            Capsule()
                                .fill(Palette.accent.opacity(0.14))
                                .matchedGeometryEffect(id: reduceMotion ? "tabPill\(tab.rawValue)" : "tabPill",
                                                       in: glass)
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
                // The glyph sits *above* the word, so it is read first: without collapsing the
                // button to one element every tab announced its SF Symbol before its name —
                // "rectangle stack, Memories". This is the app's primary navigation, and it was
                // the last control in it still doing that.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tab.title)
                // The system's own tab bar says which of how many. SwiftUI publishes no tab
                // trait to borrow, so the position is said as a hint — the one thing a reader
                // swiping along a row of three cannot otherwise work out.
                .accessibilityHint("Tab \(index + 1) of \(AppTab.allCases.count)")
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, Space.s)
        // The one place in the app that caps text growth, and it is capped rather than
        // uncapped because this bar is pinned to the bottom of the screen: it cannot get
        // taller without taking the screen with it. It still answers the setting up to the
        // first accessibility size, and every label in it is also read aloud.
        .chromeTypeSize()
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: selection)
    }

    private var exploreButton: some View {
        Button {
            isExploring = true
            Haptics.impact()
        } label: {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(Typo.glyph(18, .medium))
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
                        .font(Typo.glyph(13, .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: Hit.min, height: Hit.min)
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
                                    Spacer(minLength: Space.m)
                                    Image(systemName: "chevron.right")
                                        .font(Typo.glyph(12, .semibold))
                                        .foregroundStyle(Palette.textTertiary)
                                        // The one arrow in this panel that means "forwards",
                                        // which is leftwards in a right-to-left layout.
                                        .flipsForRightToLeftLayoutDirection(true)
                                }
                                .padding(.horizontal, Space.l)
                                // Eleven points above and below a sixteen-point line is a
                                // forty-two point row, and every row in this panel is a
                                // destination. Two short is still short.
                                .frame(minHeight: Hit.min)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(window.title)
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                .padding(.bottom, Space.l)
            }
            .scrollIndicators(.hidden)
            // Against the window rather than against a number. Three hundred and eighty points
            // is more than the whole height of an iPhone lying on its side, so the panel used to
            // open taller than the screen it was opening on and its own close button went with
            // it. Two thirds of what there is, and never more than the list needs.
            .frame(maxHeight: max(200, min(380, availableHeight * 0.62)))
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
