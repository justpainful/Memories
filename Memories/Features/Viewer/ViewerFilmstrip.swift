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

    /// What the scroll view considers centred. Kept separate from `current` so an external
    /// page turn and a drag on the strip can both drive the other without chasing each other:
    /// each side only assigns when the two have actually diverged.
    @State private var centred: String?

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
        .background(ViewerSurface.fill, in: .rect(cornerRadius: Radius.hero))
        .padding(.horizontal, Space.gutter)
        .animation(.smooth(duration: 0.22), value: current)
        .onChange(of: centred) { _, scrolled in
            guard let scrolled, scrolled != current else { return }
            current = scrolled
            Haptics.selection()
        }
        .onChange(of: current) { _, page in
            guard centred != page else { return }
            withAnimation(.smooth(duration: 0.25)) { centred = page }
        }
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
                        // brightening it, so the strip stays a row of photographs.
                        RoundedRectangle(cornerRadius: Radius.thumb)
                            .strokeBorder(Color.white, lineWidth: 2)
                    } else {
                        RoundedRectangle(cornerRadius: Radius.thumb)
                            .fill(Palette.photoScrim)
                    }
                }
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
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private func label(for identifier: String) -> String {
        guard let index = identifiers.firstIndex(of: identifier) else { return "Photo" }
        return "Photo \(index + 1) of \(identifiers.count)"
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
