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

    /// Called as each tile comes into view. Cheap on all but every sixth call.
    func tileAppeared(at index: Int, identifiers: [String], side: CGFloat) {
        guard !identifiers.isEmpty else { return }
        if let centre, abs(index - centre) < Self.step { return }
        centre = index

        let lower = max(0, index - Self.behind)
        let upper = min(identifiers.count, index + Self.ahead)
        guard lower < upper else { return }

        let window = Array(identifiers[lower..<upper])
        let requested = side * UIScreen.main.scale
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
        centre = nil
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
