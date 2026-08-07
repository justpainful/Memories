import SwiftUI

/// The thumbnail scrubber along the bottom of the full-screen viewer.
///
/// Meant to be added to `PhotoViewerView` in `Memories/Features/Viewer/PhotoViewerView.swift`:
/// inside the `if showControls` overlay, directly above `bottomCluster`, as
/// `ViewerFilmstrip(identifiers: identifiers, current: $current)`. It fades in and out with
/// the rest of the controls and needs no other wiring — the binding it shares with the pager
/// is the whole contract, so dragging the strip turns the page and turning the page moves the
/// strip.
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

    private let selectedSide: CGFloat = 52
    private let restingSide: CGFloat = 36

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
                            max(0, (proxy.size.width - selectedSide) / 2),
                            for: .scrollContent)
        }
        .frame(height: selectedSide)
        .padding(.vertical, Space.s)
        // The strip is a control, not content, and it floats over a photograph the user is
        // deliberately looking at — so clear, which lets the picture stay the brightest thing
        // on screen instead of putting a frosted band across the bottom of it.
        .glassPanel(cornerRadius: Radius.hero, tone: .clear)
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
        let side = isCurrent ? selectedSide : restingSide

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
