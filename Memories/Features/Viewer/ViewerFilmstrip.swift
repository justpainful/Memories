import SwiftData
import SwiftUI

/// The thumbnail scrubber along the bottom of the full-screen viewer.
///
/// It sits in the viewer's control column directly above the button cluster, sharing that slot
/// with the video transport — one or the other, never both. The binding it shares with the
/// pager is the whole contract: dragging the strip turns the page and turning the page moves
/// the strip.
///
/// It is deliberately lazy. A memory can hold hundreds of photographs, and a strip that
/// realised all of them would ask Photos for hundreds of thumbnails the moment the viewer
/// opened. Only what is on screen is ever built.
struct ViewerFilmstrip: View {
    let identifiers: [String]
    @Binding var current: String

    @Environment(\.app) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// What the scroll view considers centred. Kept separate from `current` so an external
    /// page turn and a drag on the strip can both drive the other without chasing each other:
    /// each side only assigns when the two have actually diverged.
    @State private var centred: String?

    /// What each cell is, beyond a picture.
    ///
    /// The strip used to know nothing about its own contents: every cell drew as a still, so
    /// scrubbing a memory of mixed media there was no way to tell a clip from a photograph
    /// until you landed on it — and no way at all under VoiceOver, which heard only "Photo 7 of
    /// 214" and had the ordinal as the single piece of information available. The rows are
    /// already indexed, so this is one fetch for the whole strip rather than one per cell.
    @State private var facts: [String: CellFacts] = [:]

    private struct CellFacts {
        let isVideo: Bool
        let isLivePhoto: Bool
        let duration: TimeInterval
        let date: Date
    }

    /// One cell, whether or not it holds the selected photograph, and comfortably past the
    /// smallest target Apple will vouch for. This is a scrubber for a set that can run to
    /// hundreds, so it is the thing in the viewer most often aimed at and it was the smallest.
    private let cellSide: CGFloat = 56
    private let restingSide: CGFloat = 42

    init(identifiers: [String], current: Binding<String>) {
        self.identifiers = identifiers
        self._current = current
        _centred = State(initialValue: current.wrappedValue)
    }

    var body: some View {
        // A strip of one is not a scrubber.
        if identifiers.count > 1 {
            strip
        }
    }

    private var strip: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Space.xs) {
                    ForEach(identifiers, id: \.self) { identifier in
                        thumbnail(identifier)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centred, anchor: .center)
            // Without this the first and last photographs could never reach the middle, so
            // the strip would refuse to select either end of the set.
            .contentMargins(.horizontal,
                            max(0, (proxy.size.width - cellSide) / 2),
                            for: .scrollContent)
        }
        .frame(height: cellSide)
        .padding(.vertical, Space.s)
        // Flat, not glass. The strip is a wide panel with a long straight top edge, and over
        // the viewer's black backdrop Liquid Glass has nothing to refract there — all that
        // survives is the specular highlight along that edge, which draws as a hard white line
        // across a dark slab and reads as a rendering fault. See `ViewerSurface`.
        //
        // Reduce Transparency takes the last of the picture out from under it: a reader who has
        // turned that on is asking for a surface, not a weaker wash.
        .background(reduceTransparency ? Color.black : ViewerSurface.fill,
                    in: .rect(cornerRadius: Radius.hero))
        .padding(.horizontal, Space.gutter)
        // Both of these move the whole strip on every page turn — one grows the newly current
        // thumbnail and shrinks the last, the other scrolls the row under the thumb — and
        // holding a swipe runs them continuously. With Reduce Motion the strip still lands on
        // the right cell; it just does not glide there.
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: current)
        .onChange(of: centred) { _, scrolled in
            guard let scrolled, scrolled != current else { return }
            current = scrolled
            Haptics.selection()
        }
        .onChange(of: current) { _, page in
            guard centred != page else { return }
            if reduceMotion {
                centred = page
            } else {
                withAnimation(.smooth(duration: 0.25)) { centred = page }
            }
        }
        .task(id: identifiers) { loadFacts() }
        // The label used to sit on the scroll view, whose children are already accessibility
        // elements of their own, so SwiftUI dropped it and the strip announced no purpose at
        // all. A container element is what a label can land on.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo scrubber")
    }

    private func thumbnail(_ identifier: String) -> some View {
        let isCurrent = identifier == current
        let side = isCurrent ? cellSide : restingSide

        return Button {
            guard !isCurrent else { return }
            current = identifier
            Haptics.selection()
        } label: {
            PhotoThumbnail(identifier: identifier, side: side, radius: Radius.thumb)
                .overlay {
                    if isCurrent {
                        // The one under the finger is named by a hairline rather than by
                        // brightening it, so the strip stays a row of photographs. Increase
                        // Contrast thickens it, since the border is the only thing in the strip
                        // carrying the selection.
                        RoundedRectangle(cornerRadius: Radius.thumb)
                            .strokeBorder(Color.white, lineWidth: contrast == .increased ? 3 : 2)
                    } else {
                        RoundedRectangle(cornerRadius: Radius.thumb)
                            .fill(contrast == .increased ? Palette.labelScrim : Palette.photoScrim)
                    }
                }
                // Inside the picture rather than over the cell, so it marks the photograph it
                // belongs to and cannot reach the neighbouring one.
                .overlay(alignment: .bottomLeading) { badge(for: identifier) }
                // The cell is the same size whichever photograph is selected, and the picture
                // inside it grows rather than the cell. Letting the cell grow re-flowed the
                // whole row at every step of a scrub, so the thumbnails slid out from under the
                // finger that was choosing between them. It is also what makes the target a
                // full cell wide instead of only as wide as the small picture drawn in it.
                .frame(width: cellSide, height: cellSide)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(for: identifier))
        .accessibilityValue(position(of: identifier))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// A clip or a Live Photo says so, the way every grid tile in the app already does.
    ///
    /// A symbol rather than a tint, so it survives a greyscale rendering and Differentiate
    /// Without Color; fixed size rather than scaled, because a fifty-six-point cell cannot grow
    /// and a glyph that outgrew it would land on the picture beside it. What a reader who needs
    /// larger text gets instead is the cell's label.
    @ViewBuilder
    private func badge(for identifier: String) -> some View {
        if let facts = facts[identifier], facts.isVideo || facts.isLivePhoto {
            Image(systemName: facts.isVideo ? "play.fill" : "livephoto")
                .font(Typo.glyph(10))
                .foregroundStyle(.white)
                // A tight dark edge rather than a soft halo: it has to hold a white glyph
                // against a white photograph, which a wide faint shadow only greys.
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .padding(4)
                // The kind is already the first thing the cell's label says.
                .accessibilityHidden(true)
        }
    }

    /// What the cell is and when it was taken.
    ///
    /// An ordinal on its own — "Photo 7 of 214" — is no way to find a particular moment in a
    /// long memory, and it was the only thing said. The date is what the reader is actually
    /// scrubbing towards; the position moved to the value, where VoiceOver says it second.
    private func label(for identifier: String) -> String {
        guard let facts = facts[identifier] else { return "Photo" }
        let day = facts.date.formatted(date: .abbreviated, time: .omitted)
        if facts.isVideo {
            return "Video, \(facts.duration.spokenDuration), \(day)"
        }
        return facts.isLivePhoto ? "Live Photo, \(day)" : "Photo, \(day)"
    }

    /// Where in the set this cell sits.
    ///
    /// Both numbers go through `formatted()` rather than straight into the string. They are
    /// numbers a person reads, and interpolating an `Int` writes ASCII digits whatever the
    /// reader's locale uses — which in a strip whose whole purpose is position is the one place
    /// it would be noticed.
    private func position(of identifier: String) -> String {
        guard let index = identifiers.firstIndex(of: identifier) else { return "" }
        return "\((index + 1).formatted()) of \(identifiers.count.formatted())"
    }

    /// One indexed read for the whole strip, on the way in.
    ///
    /// Not one per cell: the cells are built lazily as they scroll into view, and a fetch inside
    /// a cell body would run during a scrub, on the main thread, for every thumbnail the finger
    /// passes over.
    private func loadFacts() {
        let records = LibraryQuery.records(for: identifiers, context: app.container.mainContext)
        var found: [String: CellFacts] = [:]
        for record in records {
            found[record.localIdentifier] = CellFacts(isVideo: record.isVideo,
                                                      isLivePhoto: record.isLivePhoto,
                                                      duration: record.duration,
                                                      date: record.momentDate)
        }
        facts = found
    }
}

// MARK: - Preview

private struct ViewerFilmstripPreview: View {
    @State private var current = "preview-4"
    private let identifiers = (0..<30).map { "preview-\($0)" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: Space.m) {
                Spacer()
                Text(current)
                    .font(Typo.meta)
                    .foregroundStyle(.white.opacity(0.8))
                ViewerFilmstrip(identifiers: identifiers, current: $current)
                    .padding(.bottom, Space.xl)
            }
        }
    }
}

#Preview {
    ViewerFilmstripPreview()
}
