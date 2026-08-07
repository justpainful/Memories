import AVFoundation
import Photos
import SwiftUI
import UIKit

/// Why an image is being requested, which decides whether iCloud may be touched.
///
/// The rule from the spec: indexing must never pull originals down from iCloud, so an asset
/// that is not on the device is catalogued from metadata and skipped by the pixel stages.
/// When the user deliberately opens a photo full screen, fetching it is exactly what they
/// asked for, so that path is allowed to use the network — to *Apple's* iCloud, which is
/// where the photo already lives. Nothing is ever sent anywhere.
enum ImagePurpose {
    case indexing
    case browsing
    case display

    var allowsNetwork: Bool { self == .display }

    var deliveryMode: PHImageRequestOptionsDeliveryMode {
        switch self {
        case .indexing: return .fastFormat
        case .browsing: return .opportunistic
        case .display:  return .highQualityFormat
        }
    }
}

/// Loads and caches thumbnails, and reports which assets are not available offline.
@MainActor
final class PhotoImageLoader {
    static let shared = PhotoImageLoader()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    /// Assets Photos told us live only in iCloud. Recorded so indexing can skip them and the
    /// UI can show an honest placeholder instead of a spinner that never resolves.
    private(set) var cloudOnlyIdentifiers: Set<String> = []

    private init() {
        cache.countLimit = 900
        cache.totalCostLimit = 96 * 1024 * 1024
        manager.allowsCachingHighQualityImages = false
    }

    // MARK: Requests

    func image(for asset: PHAsset,
               targetSize: CGSize,
               purpose: ImagePurpose = .browsing,
               contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let key = Self.cacheKey(asset.localIdentifier, targetSize, purpose)
        if let cached = cache.object(forKey: key) { return cached }

        let options = Self.options(for: purpose)
        let image: UIImage? = await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(for: asset,
                                 targetSize: targetSize,
                                 contentMode: contentMode,
                                 options: options) { image, info in
                // `.opportunistic` calls back twice; only the final result should resume.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true

                if (info?[PHImageResultIsInCloudKey] as? Bool) == true, image == nil {
                    self.cloudOnlyIdentifiers.insert(asset.localIdentifier)
                }
                continuation.resume(returning: image)
            }
        }

        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    func image(forIdentifier identifier: String,
               targetSize: CGSize,
               purpose: ImagePurpose = .browsing) async -> UIImage? {
        guard let asset = PhotoLibraryService.asset(for: identifier) else { return nil }
        return await image(for: asset, targetSize: targetSize, purpose: purpose)
    }

    /// Small square thumbnail used by grids, strips and the calendar.
    func thumbnail(forIdentifier identifier: String, side: CGFloat = 200) async -> UIImage? {
        await image(forIdentifier: identifier,
                    targetSize: CGSize(width: side * 2, height: side * 2),
                    purpose: .browsing)
    }

    /// Defaults to `.display` because the only caller is the full-screen viewer, which the
    /// user reached by deliberately opening a photograph. The parameter exists so that
    /// policy is stated rather than assumed.
    func livePhoto(for asset: PHAsset,
                   targetSize: CGSize,
                   purpose: ImagePurpose = .display) async -> PHLivePhoto? {
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = purpose.allowsNetwork

        return await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestLivePhoto(for: asset,
                                     targetSize: targetSize,
                                     contentMode: .aspectFill,
                                     options: options) { livePhoto, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: livePhoto)
            }
        }
    }

    func playerItem(for asset: PHAsset, purpose: ImagePurpose = .display) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = purpose.allowsNetwork

        return await withCheckedContinuation { continuation in
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: Prefetching

    func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets,
                                   targetSize: targetSize,
                                   contentMode: .aspectFill,
                                   options: Self.options(for: .browsing))
    }

    func stopCaching(_ assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets,
                                  targetSize: targetSize,
                                  contentMode: .aspectFill,
                                  options: Self.options(for: .browsing))
    }

    func clearMemoryCache() {
        cache.removeAllObjects()
        manager.stopCachingImagesForAllAssets()
    }

    // MARK: Plumbing

    private static func options(for purpose: ImagePurpose) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = purpose.allowsNetwork
        options.deliveryMode = purpose.deliveryMode
        options.resizeMode = purpose == .display ? .none : .fast
        options.isSynchronous = false
        return options
    }

    private static func cacheKey(_ identifier: String,
                                 _ size: CGSize,
                                 _ purpose: ImagePurpose) -> NSString {
        "\(identifier)|\(Int(size.width))x\(Int(size.height))|\(purpose.deliveryMode.rawValue)" as NSString
    }
}
