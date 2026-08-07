import SwiftUI

/// How the app answers the size of the window it has actually been given.
///
/// The app was built portrait-on-one-phone and said so in its Info.plist, so nothing in it ever
/// had to ask how wide it was. Now that it runs in landscape and on iPad, "three across" and
/// "the hero is 1.2 screens tall" stop being layouts and start being coincidences — three
/// photographs across a 1024-point iPad are 340 points each, and a hero measured against the
/// *height* of a portrait phone fills a landscape one twice over.
///
/// So the rule everywhere in this app is: **ask the container, never the device.** There is no
/// `UIScreen` in this file and there is none anywhere else; every number below is derived from
/// the width the view was handed, which is the only number that is true in Split View, in Slide
/// Over, in Stage Manager and on a phone lying on its side.
enum Adaptive {

    /// The width the layout was designed against — one iPhone, portrait.
    ///
    /// Kept as a named reference rather than scattered as `393` so the derivations below read
    /// as "the same tile, more of them" instead of as magic arithmetic.
    static let referenceWidth: CGFloat = 393

    // MARK: Photographs across a grid

    /// The number of columns a grid of the given density should draw in the given width.
    ///
    /// The user's pinch chooses a *density* — how big a photograph they want to look at — and
    /// this turns that into a column count for the width actually available. On the phone it
    /// returns exactly the ladder rung the pinch selected, which is what it has always done.
    /// On anything wider it returns more columns of the same size, which is what Photos does
    /// and what the gesture means.
    static func gridColumns(density: Int, width: CGFloat) -> Int {
        guard width > 0 else { return density }
        let tile = referenceWidth / CGFloat(density)
        return max(density, Int((width / tile).rounded()))
    }

    // MARK: Measure

    /// The widest a column of prose, a form or a row of cards should be allowed to get.
    ///
    /// A settings list stretched across a landscape iPad is a line of text with a switch a foot
    /// away from it. Content that is read stops at a comfortable measure and centres; content
    /// that is *looked at* — the grids, the map, the feed's photography — is not capped and
    /// takes the whole window.
    static let readableWidth: CGFloat = 700

    /// The height a full-bleed hero should take, given the size of its container.
    ///
    /// Proportional to the *smaller* side, so a hero cannot swallow a landscape window: on a
    /// portrait phone this is the tall editorial cover it has always been, and turned sideways
    /// it becomes a wide one instead of a picture taller than the screen.
    static func heroHeight(in size: CGSize) -> CGFloat {
        let base = min(size.width, size.height)
        return min(max(base * 1.15, 320), size.height * 0.86)
    }

    /// How many cards fit across a horizontally scrolling row.
    ///
    /// Returns the card's width rather than a count, because these rows are carousels: the
    /// point is that the next card peeks in from the edge, and that peek is what tells the user
    /// the row scrolls at all.
    static func carouselCardWidth(in width: CGFloat, ideal: CGFloat) -> CGFloat {
        guard width > 0 else { return ideal }
        let visible = max(1, (width / ideal).rounded(.down))
        // Leave a peek: divide by a half-card more than fits, never by fewer than 1.2.
        return width / max(1.2, visible + 0.28)
    }
}

// MARK: - The floating bar's footprint

/// How much room the floating tab bar takes at the bottom of the screen.
///
/// Every scrolling screen in the app has to end above the bar, and every one of them used to do
/// it by writing `132` — a number measured once, on one phone, at the default text size, and
/// then copied into twenty files. It is wrong the moment the reader turns on larger text (the
/// bar grows and the last row goes under it), wrong in landscape (the home indicator inset
/// changes) and wrong on iPad.
///
/// So the bar measures itself and publishes the answer here, and the screens ask.
private struct BottomBarInsetKey: EnvironmentKey {
    /// What the bar comes out at on a portrait iPhone at the default text size. Only ever seen
    /// for the one frame before the real measurement arrives, and in previews.
    static let defaultValue: CGFloat = 132
}

extension EnvironmentValues {
    var bottomBarInset: CGFloat {
        get { self[BottomBarInsetKey.self] }
        set { self[BottomBarInsetKey.self] = newValue }
    }
}

// The bar reports its height by writing into a binding its owner holds — see
// `measuringBarHeight` below — rather than through a `PreferenceKey`. A preference would travel
// *up* the tree, which is the natural direction, but its callback is not main-actor isolated and
// the value it feeds is view state; the simple version of that is a concurrency warning and the
// careful version is three lines of hop-to-the-main-actor for a number the owner is standing
// right next to.

// MARK: - Reading the container

/// The width of the view this is attached to, without a `GeometryReader`.
///
/// `GeometryReader` cannot be used for this: it takes all the space offered in *both*
/// directions, so wrapping a lazy grid in one collapses the scroll view's content height to
/// zero. `onGeometryChange` reports the same number and changes nothing about the layout.
extension View {
    func measuringWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            if abs(new - width.wrappedValue) > 0.5 { width.wrappedValue = new }
        }
    }

    /// The view's height *including* the safe area below it, which for a bottom-anchored bar is
    /// the whole of the room it takes away from the screen.
    func measuringBarHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.bottom } action: { new in
            if abs(new - height.wrappedValue) > 0.5 { height.wrappedValue = new }
        }
    }

    /// Centre and cap this view at a readable measure, and leave it alone on a phone.
    ///
    /// `frame(maxWidth:)` alone would also stretch a view that wanted to be small, so the
    /// alignment is stated: the content keeps its natural size up to the cap and is centred in
    /// whatever is left over.
    func readableMeasure(_ cap: CGFloat = Adaptive.readableWidth) -> some View {
        frame(maxWidth: cap)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
