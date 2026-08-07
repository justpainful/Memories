import SwiftData
import SwiftUI

/// The editorial furniture of the feed.
///
/// None of these are glass. Glass belongs to controls; content is photography on paper, and
/// putting every card behind a pane of it would turn the app into a WWDC demo.
///
/// Every measurement below that used to be a point size is now a fraction of the width the
/// section was actually handed. The numbers were all chosen against one portrait iPhone, which
/// is fine until the app is asked to draw the same composition in a 320-point Slide Over pane
/// or across a 1024-point iPad, where a 118-point column beside a hero that has grown to 880
/// stops being an asymmetric cluster and becomes one photograph with two postage stamps.

// MARK: - Header

struct SectionHeader: View {
    let overline: String?
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let overline {
                Text(overline).overlineStyle()
            }
            Text(title)
                .font(Typo.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                // Memory titles are assembled from place and people names, so their length is
                // the reader's library rather than anything this app chose. Three lines and a
                // small shrink is generous enough for the long ones and stops the very longest
                // pushing the photographs below off the screen.
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            if let subtitle {
                Text(subtitle)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        // The feed wraps this in a button that opens the memory. A button is hit only where
        // it draws, and a headline draws to the end of its words — so everything to the right
        // of the title, which on a short one is most of the row, did nothing at all.
        .contentShape(.rect)
        // This is the app's only reusable heading, and without the trait the headings rotor is
        // empty on every screen that uses it — which means reaching the next memory costs a
        // swipe per photograph in the one above.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Hero

/// One photograph, edge to edge, with the memory's name written on it.
struct HeroMemoryCard: View {
    let candidate: MemoryCandidate

    /// The size of the window the feed is being drawn in.
    ///
    /// The card used to declare `.aspectRatio(0.8)` and let the layout work out the rest, which
    /// is a portrait poster whatever shape the container is: 1280 points tall in a 1024-point
    /// iPad window, 1065 in a landscape phone that is 393 points tall in total. A hero is
    /// supposed to be the thing the page opens on, not three screenfuls of scrolling before the
    /// second memory. `Adaptive.heroHeight(in:)` derives it from the smaller side of whatever
    /// container arrived, so turned sideways the card becomes a wide one instead of a tall one.
    var containerSize: CGSize = .zero

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// How tall the caption actually came out, so the scrim can be exactly as tall.
    @State private var captionHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The height the card wants, stated as an empty view rather than as a frame on the
            // whole card. A frame is a ceiling as well as a floor, and the caption is the one
            // thing here that can legitimately exceed it — a three-line title at the largest
            // accessibility size is taller than the picture was ever asked to be. Said this way
            // the card grows to hold it instead of slicing the top off the memory's name.
            Color.clear.frame(height: cardHeight)

            caption
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(height - captionHeight) > 0.5 { captionHeight = height }
                }
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .background { cover }
        .accessibilityElement(children: .combine)
        // Joined rather than interpolated: a memory without a subtitle was being announced
        // with a full stop and a silence after it. The count carries its unit, because a bare
        // number read after a place name is heard as a year at least as often as a quantity.
        .accessibilityLabel([candidate.title,
                             candidate.subtitle,
                             "\(candidate.assetCount.formatted()) photos"]
            .compactMap { $0 }
            .joined(separator: ". "))
    }

    /// The photograph and the scrim it needs, in that order, both behind the caption.
    ///
    /// They are the card's background rather than layers in the same stack so that the scrim can
    /// be measured against the caption above it without the caption's own height depending on
    /// the scrim's — which is the loop that a `ZStack` of all three would create.
    private var cover: some View {
        ZStack(alignment: .bottom) {
            if let identifier = candidate.coverIdentifier {
                // Browsing, not display: the feed must never quietly pull originals down
                // from iCloud just by being scrolled past.
                PhotoImageView(identifier: identifier,
                               targetSide: max(containerSize.width, Adaptive.referenceWidth),
                               purpose: .browsing)
            } else {
                Palette.surfaceSunk
            }

            scrim.frame(height: scrimHeight)
        }
    }

    /// A gradient sized to the words, not to the card.
    ///
    /// It used to run from the card's centre to its bottom, which covered the caption at the
    /// default text size and nothing like it at the largest: a three-line title plus overline
    /// plus subtitle is a 400-point block that starts well above the midpoint, so the memory's
    /// name ended up as white type on the bare photograph. Over a snowfield or a blown-out sky
    /// that is not a weak contrast ratio, it is an invisible title. Anchoring the scrim to the
    /// measured caption means the guarantee holds at every size instead of at one.
    @ViewBuilder
    private var scrim: some View {
        if reduceTransparency {
            // Reduce Transparency is a request for a surface. A fade that lets the picture
            // through is the thing being turned off, so the caption gets a band to sit on.
            Color.black.opacity(0.92)
        } else {
            LinearGradient(
                colors: [.clear,
                         .black.opacity(contrast == .increased ? 0.45 : 0.20),
                         .black.opacity(contrast == .increased ? 0.90 : 0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(candidate.kind.fallbackTitle)
                .font(Typo.overline)
                .textCase(.uppercase)
                .kerning(0.7)
                .foregroundStyle(.white.opacity(boostedText ? 1 : 0.72))

            Text(candidate.title)
                .font(Typo.editorial(32))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
                .minimumScaleFactor(0.6)

            if let subtitle = candidate.subtitle {
                Text(subtitle)
                    .font(Typo.label)
                    .foregroundStyle(.white.opacity(boostedText ? 1 : 0.82))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xl)
    }

    /// Sub-full-opacity white over a partly transparent scrim over an unknown photograph is
    /// exactly what these two settings exist to correct.
    private var boostedText: Bool {
        contrast == .increased || reduceTransparency
    }

    private var cardHeight: CGFloat {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return Adaptive.referenceWidth * 1.25
        }
        let derived = Adaptive.heroHeight(in: containerSize)
        // On a regular-width window the smaller side is still a thousand points, so the
        // proportional answer is a card taller than the screen it is on. There a hero should
        // behave like an editorial banner rather than a poster.
        return horizontalSizeClass == .regular ? min(derived, 560) : derived
    }

    /// The scrim covers the caption plus enough above it for the fade to arrive gradually
    /// rather than as a line. Before the caption has been measured it falls back to the bottom
    /// half of the card, which is where the gradient used to start.
    private var scrimHeight: CGFloat {
        guard captionHeight > 0 else { return cardHeight * 0.5 }
        return captionHeight + Space.section
    }
}

// MARK: - Mosaic

/// An asymmetric cluster: one frame that carries the occasion, and the rest around it.
struct MosaicSection: View {
    let identifiers: [String]

    /// The width of the container the cluster is laid out in. Zero falls back to the phone the
    /// proportions below were derived from, which is what previews and the first frame get.
    var containerWidth: CGFloat = 0
    var spacing: CGFloat = 6

    var body: some View {
        let items = Array(identifiers.prefix(9))
        let width = compositionWidth
        VStack(spacing: spacing) {
            if items.count >= 3 {
                HStack(spacing: spacing) {
                    tile(items[0])
                        .frame(maxWidth: .infinity)
                    VStack(spacing: spacing) {
                        tile(items[1])
                        tile(items[2])
                    }
                    .frame(width: width * 0.33)
                }
                .frame(height: width * 0.70)

                if items.count >= 6 {
                    HStack(spacing: spacing) {
                        ForEach(items[3..<min(6, items.count)], id: \.self) { identifier in
                            tile(identifier)
                        }
                    }
                    .frame(height: width * 0.32)
                }
                if items.count >= 9 {
                    HStack(spacing: spacing) {
                        ForEach(items[6..<9], id: \.self) { identifier in
                            tile(identifier)
                        }
                    }
                    .frame(height: width * 0.32)
                }
            } else {
                HStack(spacing: spacing) {
                    ForEach(items, id: \.self) { identifier in
                        tile(identifier)
                    }
                }
                .frame(height: width * 0.57)
            }
        }
        .frame(width: width)
        // Centred rather than pinned to the leading gutter: on a phone the two are the same
        // thing, and on anything wider the cluster reads as a composition on the page instead
        // of as a block that ran out of room on one side.
        .frame(maxWidth: .infinity)
        // The feed's photographs are one element, not nine anonymous ones. The tap opens the
        // memory whichever frame it lands on, so announcing nine of them would be nine stops
        // for one destination — the wrapping button carries the memory's own name.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(items.count.formatted()) photos")
    }

    /// The width the proportions are taken from.
    ///
    /// Capped, because the mosaic is a composition rather than a grid: at 984 points across, the
    /// hero row alone would be nearly 700 points tall and the reader would scroll a full screen
    /// to get past three photographs. Below the cap — every phone, every Slide Over pane — the
    /// cap does nothing and the numbers are the ones the layout was drawn with.
    private var compositionWidth: CGFloat {
        let available = containerWidth > 0 ? containerWidth : Adaptive.referenceWidth
        return max(1, min(available - 2 * Space.gutter, Adaptive.readableWidth))
    }

    private func tile(_ identifier: String) -> some View {
        PhotoImageView(identifier: identifier, targetSide: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: Radius.tile))
    }
}

// MARK: - Strip

/// A horizontal run of cards, for memories that are a set rather than a scene.
struct StripSection: View {
    let identifiers: [String]

    /// The width of the container the row scrolls across. The card size is derived from it so
    /// that roughly the same number of cards is visible on any screen, with the next one
    /// peeking in — that peek is the only thing that tells the reader the row scrolls at all,
    /// and at a fixed 172 points it disappears in a narrow pane and multiplies to six cards
    /// across on an iPad.
    var containerWidth: CGFloat = 0
    var idealCardWidth: CGFloat = 172

    /// The cards must be tappable in their own right. A horizontal run of photographs that
    /// does nothing when touched reads as broken, whatever the header above it does — and it
    /// reads as broken in a different way when all eighteen do the *same* thing, which is what
    /// a closure taking no argument bought. The identifier under the finger is the whole point
    /// of touching one card rather than another.
    var onSelect: (String) -> Void

    var body: some View {
        let shown = Array(identifiers.prefix(18))
        let cardWidth = Adaptive.carouselCardWidth(in: containerWidth, ideal: idealCardWidth)
        ScrollView(.horizontal) {
            HStack(spacing: Space.m) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, identifier in
                    Button { onSelect(identifier) } label: {
                        PhotoImageView(identifier: identifier, targetSide: cardWidth * 2)
                            .frame(width: cardWidth, height: cardWidth * 1.25)
                            .clipShape(.rect(cornerRadius: Radius.card))
                    }
                    .buttonStyle(.plain)
                    // Without a label this is one of eighteen consecutive "Button"s. The
                    // position is what distinguishes them to a reader who cannot see which
                    // photograph is which, and it is what the card is actually offering:
                    // somewhere specific in the run to start looking.
                    .accessibilityLabel("Photo \((index + 1).formatted()) of \(shown.count.formatted())")
                }
            }
            .padding(.horizontal, Space.gutter)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - Through the years

/// Year-labelled columns. The point of the app in one control: the same week, stacked.
struct YearStripSection: View {
    let slices: [YearSlice]

    /// As with `StripSection`: the card is a proportion of the container, not a number measured
    /// once against a phone.
    var containerWidth: CGFloat = 0
    var idealCardWidth: CGFloat = 148
    var onSelect: (YearSlice) -> Void

    var body: some View {
        let cardWidth = Adaptive.carouselCardWidth(in: containerWidth, ideal: idealCardWidth)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Space.m) {
                ForEach(slices) { slice in
                    Button { onSelect(slice) } label: {
                        VStack(alignment: .leading, spacing: Space.s) {
                            if let cover = slice.coverIdentifier {
                                PhotoImageView(identifier: cover, targetSide: cardWidth * 2)
                                    .frame(width: cardWidth, height: cardWidth * 1.25)
                                    .clipShape(.rect(cornerRadius: Radius.card))
                            } else {
                                RoundedRectangle(cornerRadius: Radius.card)
                                    .fill(Palette.surfaceSunk)
                                    .frame(width: cardWidth, height: cardWidth * 1.25)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                // Years are written, never grouped: a thousand-separator turns
                                // 2019 into 2,019.
                                Text(slice.year.formatted(.number.grouping(.never)))
                                    .font(Typo.label.weight(.semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Text("\(slice.count.formatted()) \(slice.count == 1 ? "moment" : "moments")")
                                    .font(Typo.meta)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        }
                        // The caption used to be the only part of the card with no width, so
                        // "1,247 moments" at an accessibility size made that column wider than
                        // its own photograph and every card in the row a different width —
                        // which is also what made `viewAligned` snap to offsets that did not
                        // line up with anything.
                        .frame(width: cardWidth, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    // One stop per year rather than a photograph and two loose lines of text,
                    // and the count says what it is counting.
                    .accessibilityLabel(label(for: slice))
                }
            }
            .padding(.horizontal, Space.gutter)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    private func label(for slice: YearSlice) -> String {
        let year = slice.year.formatted(.number.grouping(.never))
        let moments = slice.count == 1 ? "moment" : "moments"
        return "\(year), \(slice.count.formatted()) \(moments)"
    }
}

// MARK: - Empty and loading

struct QuietStatusView: View {
    let title: String
    var detail: String?
    var symbol: String = "sparkles"

    /// A way out of the state being described, where one exists.
    ///
    /// Every empty state in the app comes through here, and the two that matter most — no photo
    /// access, and access to only a handful — end by telling the reader to go to Settings and
    /// then leaving them to find it. Optional rather than required because most of these states
    /// are genuinely just waiting, and a button that does nothing useful is worse than none.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.m) {
            VStack(spacing: Space.m) {
                Image(systemName: symbol)
                    .font(Typo.scaled(28, .light))
                    .foregroundStyle(Palette.textTertiary)
                    // Decoration. Left alone it is announced by the symbol's own name, so every
                    // empty state in the app opened with "sparkles" or "mappin.slash".
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typo.quiet)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            // Combined so the explanation is one statement rather than two stops. The button
            // stays outside it, because a combined element is not a tappable one.
            .accessibilityElement(children: .combine)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    // Large rather than default so the capsule clears the smallest target
                    // Apple will vouch for without the height being written out as a number.
                    .controlSize(.large)
                    .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.section)
        .padding(.vertical, Space.section)
        // Two lines of centred explanation stretched across an iPad is a paragraph nobody can
        // follow the second line of.
        .readableMeasure()
    }
}
