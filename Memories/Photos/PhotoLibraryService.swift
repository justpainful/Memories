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

    init() {
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
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor in
                self?.changeGeneration &+= 1
                self?.assetCount = Self.currentAssetCount()
            }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
        assetCount = Self.currentAssetCount()
    }

    // MARK: Fetching

    /// All assets the app is allowed to see, newest first.
    ///
    /// `includeAssetSourceTypes` deliberately excludes `.typeCloudShared`: shared-album
    /// content is not the user's own library and has no business appearing in their memories.
    static func makeFetchOptions(includeHidden: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = includeHidden
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        return options
    }

    static func currentAssetCount() -> Int {
        PHAsset.fetchAssets(with: makeFetchOptions()).count
    }

    /// Walk the whole library without materialising it: `PHFetchResult` is lazy, and the
    /// snapshots are produced in chunks so a 100k library never sits in memory at once.
    func enumerateSnapshots(chunkSize: Int = 500,
                            handler: @escaping ([AssetSnapshot]) async -> Void) async {
        let result = PHAsset.fetchAssets(with: Self.makeFetchOptions())
        var buffer: [AssetSnapshot] = []
        buffer.reserveCapacity(chunkSize)

        for index in 0..<result.count {
            buffer.append(AssetSnapshot(result.object(at: index)))
            if buffer.count >= chunkSize {
                await handler(buffer)
                buffer.removeAll(keepingCapacity: true)
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
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
