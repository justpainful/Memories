import Foundation
import Observation
import Photos
import PhotosUI   // presentLimitedLibraryPicker(from:) lives here, not in Photos
import UIKit

/// A plain-value description of a `PHAsset`, safe to hand to background work.
///
/// `PHAsset` is a live object tied to the library; snapshotting the handful of fields the
/// indexer needs keeps the fetch on one thread and the analysis anywhere.
struct AssetSnapshot: Sendable, Hashable {
    var localIdentifier: String
    var creationDate: Date
    var modificationDate: Date?
    var mediaTypeRaw: Int
    var mediaSubtypesRaw: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
    var isFavorite: Bool
    var burstIdentifier: String?
    var latitude: Double?
    var longitude: Double?

    init(_ asset: PHAsset) {
        localIdentifier = asset.localIdentifier
        creationDate = asset.creationDate ?? asset.modificationDate ?? .distantPast
        modificationDate = asset.modificationDate
        mediaTypeRaw = asset.mediaType.rawValue
        mediaSubtypesRaw = Int(asset.mediaSubtypes.rawValue)
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
        duration = asset.duration
        isFavorite = asset.isFavorite
        burstIdentifier = asset.burstIdentifier
        latitude = asset.location?.coordinate.latitude
        longitude = asset.location?.coordinate.longitude
    }
}

/// What Photos says actually changed, rather than merely that something did.
///
/// `PHChange` will name the assets involved, which is the difference between ingesting the one
/// photo the user just took and re-reading fifteen thousand rows to find it.
struct LibraryDelta: Sendable {
    var inserted: [AssetSnapshot] = []
    var updated: [AssetSnapshot] = []
    var removedIdentifiers: [String] = []

    /// How many assets the library holds now, carried along so nobody has to count again.
    var libraryCount: Int = 0

    /// False when Photos could not describe the change asset by asset — a Limited Access
    /// selection being edited, most often. Only a full pass can tell what happened then.
    var isIncremental: Bool = true

    var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removedIdentifiers.isEmpty
    }
}

/// How much of the library the app can see.
enum PhotoAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case full

    var canRead: Bool { self == .full || self == .limited }

    var title: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .denied:        return "No access"
        case .restricted:    return "Restricted"
        case .limited:       return "Limited access"
        case .full:          return "Full library"
        }
    }
}

/// Owns the app's relationship with Photos: permission, fetching, and change notifications.
///
/// Limited Access is treated as a first-class mode rather than a degraded one — the app
/// simply curates whatever set of assets it was given, and offers the system picker to widen it.
@MainActor
@Observable
final class PhotoLibraryService {
    private(set) var access: PhotoAccess = .notDetermined
    private(set) var assetCount: Int = 0
    /// Bumped whenever the library changes, so views and the indexer can react.
    private(set) var changeGeneration: Int = 0

    private var observer: LibraryChangeObserver?
    private let deltas: AsyncStream<LibraryDelta>
    private let deltaContinuation: AsyncStream<LibraryDelta>.Continuation

    /// What changed, for the one consumer that acts on it rather than merely redrawing:
    /// the indexing coordinator.
    ///
    /// Buffered rather than dropped, because a photo taken while a pass is busy still has to
    /// be indexed — just not this instant.
    var changes: AsyncStream<LibraryDelta> { deltas }

    init() {
        let (stream, continuation) = AsyncStream<LibraryDelta>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        deltas = stream
        deltaContinuation = continuation
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    // MARK: Permission

    @discardableResult
    func requestAccess() async -> PhotoAccess {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
        access = Self.map(status)
        if access.canRead { startObserving() }
        return access
    }

    func refreshAccess() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if access.canRead { startObserving() }
    }

    /// Present the system sheet that lets the user add more photos to a Limited selection.
    func presentLimitedLibraryPicker(from controller: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized: return .full
        case .limited:    return .limited
        case .denied:     return .denied
        case .restricted: return .restricted
        default:          return .notDetermined
        }
    }

    // MARK: Change observing

    func startObserving() {
        guard observer == nil else { return }
        let result = PHAsset.fetchAssets(with: Self.makeFetchOptions())
        assetCount = result.count

        let observer = LibraryChangeObserver(tracking: result) { [weak self] delta in
            Task { @MainActor in self?.publish(delta) }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    /// Views that only care that *something* moved keep working off the generation counter;
    /// the indexer takes the delta itself.
    private func publish(_ delta: LibraryDelta) {
        assetCount = delta.libraryCount
        changeGeneration &+= 1
        deltaContinuation.yield(delta)
    }

    // MARK: Fetching

    /// All assets the app is allowed to see, newest first.
    ///
    /// `includeAssetSourceTypes` deliberately excludes `.typeCloudShared`: shared-album
    /// content is not the user's own library and has no business appearing in their memories.
    nonisolated static func makeFetchOptions(includeHidden: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = includeHidden
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        return options
    }

    nonisolated static func currentAssetCount() -> Int {
        PHAsset.fetchAssets(with: makeFetchOptions()).count
    }

    /// Walk the whole library without materialising it: `PHFetchResult` is lazy, and the
    /// snapshots are produced in chunks so a 100k library never sits in memory at once.
    ///
    /// `nonisolated` is the point of it. Lazy means every asset is faulted in from the Photos
    /// database at the moment it is reached, so a library of fifteen thousand is fifteen
    /// thousand small reads — and doing those where the frames are drawn is a launch that
    /// looks like the app has stopped responding. Static because nothing in here needs the
    /// service's own state, which is what lets it be called from anywhere.
    nonisolated static func enumerateSnapshots(chunkSize: Int = 400,
                                               handler: ([AssetSnapshot]) async -> Void) async {
        let result = PHAsset.fetchAssets(with: makeFetchOptions())
        var buffer: [AssetSnapshot] = []
        buffer.reserveCapacity(chunkSize)

        for index in 0..<result.count {
            buffer.append(AssetSnapshot(result.object(at: index)))
            if buffer.count >= chunkSize {
                await handler(buffer)
                buffer.removeAll(keepingCapacity: true)
                // Checked here rather than per asset: a cancelled sweep used to keep reading
                // to the end of the library with nowhere to put what it read.
                if Task.isCancelled { return }
            }
        }
        if !buffer.isEmpty { await handler(buffer) }
    }

    nonisolated static func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    nonisolated static func assets(for identifiers: [String]) -> [String: PHAsset] {
        guard !identifiers.isEmpty else { return [:] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in map[asset.localIdentifier] = asset }
        return map
    }
}

/// `PHPhotoLibraryChangeObserver` requires an `NSObject`; keeping it in its own tiny class
/// lets the service stay a clean `@Observable`.
///
/// It holds on to the fetch the change is measured against, because a `PHChange` will only
/// itemise a change relative to a result you already had.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable (LibraryDelta) -> Void
    /// Photos delivers one notification at a time, and this is only ever read and replaced
    /// inside that callback.
    private var tracked: PHFetchResult<PHAsset>

    init(tracking result: PHFetchResult<PHAsset>,
         onChange: @escaping @Sendable (LibraryDelta) -> Void) {
        tracked = result
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // No details means the assets we track are untouched — an album was renamed, or
        // something else the app does not look at.
        guard let details = changeInstance.changeDetails(for: tracked) else { return }
        tracked = details.fetchResultAfterChanges

        var delta = LibraryDelta()
        delta.libraryCount = tracked.count
        delta.isIncremental = details.hasIncrementalChanges

        if details.hasIncrementalChanges {
            delta.inserted = details.insertedObjects.map(AssetSnapshot.init)
            delta.updated = details.changedObjects.map(AssetSnapshot.init)
            delta.removedIdentifiers = details.removedObjects.map(\.localIdentifier)
        }
        onChange(delta)
    }
}
