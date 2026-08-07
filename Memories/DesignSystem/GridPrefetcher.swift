import Photos
import SwiftUI

/// Warms the frames that are about to come over the bottom edge.
///
/// `PHCachingImageManager` will decode ahead of a scroll, but only for assets it has been told
/// about. The app has had `startCaching`/`stopCaching` since the beginning and never called
/// them from anywhere, so every tile arrived cold: a request issued at the moment it appeared,
/// a decode, and a grey square until both finished. On a library of this size that is what
/// scrolling felt like.
///
/// The window is kept deliberately modest. Caching is not free — each warmed asset is a decode
/// Photos may perform and a bitmap it may hold — so warming the whole library would trade a
/// stutter for a memory warning.
@MainActor
final class GridPrefetcher {
    /// How far past the newest tile to warm, and how much to keep behind it for the way back.
    private static let ahead = 36
    private static let behind = 12
    /// Recomputing on every tile would cost more than it saves, so the window only moves once
    /// the scroll has travelled far enough to be worth a new request.
    private static let step = 6

    private var centre: Int?
    private var warmed: [PHAsset] = []
    private var warmedSize: CGSize = .zero
    private var work: Task<Void, Never>?

    /// What the last window was warmed *for*, as opposed to where it was centred.
    ///
    /// The step guard below asks only whether the scroll has moved far enough, which is the
    /// right question while a grid holds still and the wrong one the moment it does not. Pinch
    /// the density one rung, turn the phone, or change the filter under a stationary finger,
    /// and the tiles are a different size or a different set while the centre has not moved at
    /// all — so the prefetcher went on warming the previous size for the previous list, and
    /// every bitmap it produced was one nothing would ever ask for.
    private var lastSide: CGFloat = 0
    private var lastCount: Int = 0

    /// Called as each tile comes into view. Cheap on all but every sixth call.
    func tileAppeared(at index: Int, identifiers: [String], side: CGFloat) {
        guard !identifiers.isEmpty else { return }
        let isSameGrid = side == lastSide && identifiers.count == lastCount
        if let centre, isSameGrid, abs(index - centre) < Self.step { return }
        centre = index
        lastSide = side
        lastCount = identifiers.count

        let lower = max(0, index - Self.behind)
        let upper = min(identifiers.count, index + Self.ahead)
        guard lower < upper else { return }

        let window = Array(identifiers[lower..<upper])
        // `UITraitCollection.current` rather than `UIScreen.main`: this is not a view and has
        // no environment to read, and `UIScreen.main` names one screen in a world where an app
        // can be on several, which is why Apple deprecated it.
        //
        // The size goes through the loader's own ladder rather than being multiplied out here,
        // because warming at a size no tile will ever request is the same as not warming at
        // all: Photos matches a cached frame by its numbers, and nothing else.
        let requested = PhotoImageLoader.requestSide(forSide: side,
                                                     scale: UITraitCollection.current.displayScale)
        let size = CGSize(width: requested, height: requested)

        // Only the newest window matters; a request from two screens ago is wasted decoding.
        work?.cancel()
        work = Task { [weak self] in
            let assets = await Self.resolve(window)
            guard !Task.isCancelled, let self else { return }
            self.warm(assets, size: size)
        }
    }

    /// Hand everything back when the grid goes away, so Photos is not left decoding for a
    /// screen nobody is looking at.
    func stop() {
        work?.cancel()
        work = nil
        guard !warmed.isEmpty else { return }
        PhotoImageLoader.shared.stopCaching(warmed, targetSize: warmedSize)
        warmed = []
        warmedSize = .zero
        centre = nil
        lastSide = 0
        lastCount = 0
    }

    private func warm(_ assets: [PHAsset], size: CGSize) {
        if !warmed.isEmpty {
            PhotoImageLoader.shared.stopCaching(warmed, targetSize: warmedSize)
        }
        PhotoImageLoader.shared.startCaching(assets, targetSize: size)
        warmed = assets
        warmedSize = size
    }

    /// Turning identifiers into assets is a synchronous query against the Photos database.
    /// Doing that while a finger is on the screen is the very stall this exists to remove, so
    /// it is `nonisolated` and `async` — which is what keeps it off the caller's actor.
    private nonisolated static func resolve(_ identifiers: [String]) async -> [PHAsset] {
        let found = PhotoLibraryService.assets(for: identifiers)
        return identifiers.compactMap { found[$0] }
    }
}
