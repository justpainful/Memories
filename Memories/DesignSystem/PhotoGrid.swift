import SwiftUI

/// How many photographs sit across the width of a grid.
///
/// A ladder of counts rather than a continuous scale. A fractional column count would reflow
/// every tile on every frame of a pinch, and these grids run to tens of thousands of items —
/// the snap is what keeps the gesture fluid instead of merely possible.
enum PhotoGridDensity {
    /// Coarse to fine: a pair of large frames, the familiar three, thumbnails, and a contact
    /// sheet dense enough to cover a year in a screenful.
    static let ladder = [2, 3, 5, 7]

    /// What the app has always shown, and what Photos opens on.
    static let standard = 3

    /// Deliberately one key for every grid in the app. How densely someone likes to browse is
    /// a habit, not a property of the screen they happen to be standing on.
    static let storageKey = "photoGrid.columnCount"

    /// The rung nearest a stored count, so a value written by an older build — or one that
    /// drifted out of range — still resolves to a grid that can actually be drawn.
    static func rung(nearest count: Int) -> Int { ladder[index(nearest: count)] }

    static func index(nearest count: Int) -> Int {
        ladder.indices.min { abs(ladder[$0] - count) < abs(ladder[$1] - count) } ?? 0
    }

    /// Gutters close as the tiles shrink. At seven across, a four-point gap is most of what
    /// separates one photograph from the next.
    static func spacing(for columns: Int) -> CGFloat {
        switch columns {
        case ...4: return Space.xs
        case 5...6: return 2
        default: return 1
        }
    }
}

/// A lazy grid of square photographs whose density answers to a pinch.
///
/// Pinching a grid of pictures is among the most recognisable gestures in Photos, and an app
/// that means to sit beside it is judged on having it. The count snaps between rungs with a
/// light haptic at each one, and the choice is remembered: coming back to a screen to find it
/// re-arranged reads as a bug, not as a default.
///
/// The grid stays a `LazyVGrid`. A library this size cannot afford to build tiles it is not
/// showing, least of all at seven across.
struct PhotoGrid<Content: View>: View {
    private let content: () -> Content

    @AppStorage(PhotoGridDensity.storageKey) private var storedColumns = PhotoGridDensity.standard
    /// The magnification at which the current rung was reached. Moving it on every change is
    /// what lets one long pinch travel several rungs instead of stalling at the first.
    @State private var pinchAnchor: CGFloat = 1

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: items, spacing: spacing) {
            content()
        }
        .padding(spacing)
        .gesture(pinch)
    }

    private var columns: Int { PhotoGridDensity.rung(nearest: storedColumns) }

    private var spacing: CGFloat { PhotoGridDensity.spacing(for: columns) }

    /// Fixed columns rather than `.adaptive`: the pinch is choosing the count outright, and an
    /// adaptive grid would keep re-deriving one of its own from the available width.
    private var items: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 1), spacing: spacing), count: columns)
    }

    private var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onChanged { value in step(at: value.magnification) }
            .onEnded { _ in pinchAnchor = 1 }
    }

    /// Thresholds rather than a proportional mapping, and asymmetric ones: spreading two
    /// fingers travels further than closing them, so the outward gesture needs more room
    /// before it counts as a deliberate step.
    private func step(at magnification: CGFloat) {
        let index = PhotoGridDensity.index(nearest: storedColumns)
        let scale = magnification / pinchAnchor
        let target = scale > 1.4 ? index - 1 : (scale < 0.72 ? index + 1 : index)
        guard target != index, PhotoGridDensity.ladder.indices.contains(target) else { return }

        pinchAnchor = magnification
        withAnimation(.smooth(duration: 0.3)) {
            storedColumns = PhotoGridDensity.ladder[target]
        }
        Haptics.selection()
    }
}
