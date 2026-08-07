import Foundation
import Photos
import SwiftData

/// One row per asset in the user's library.
///
/// This is metadata *about* a photo, never the photo. The original stays in Photos and is
/// re-requested by `localIdentifier` whenever it needs to be shown. A library of 100k items
/// therefore costs tens of megabytes here, not tens of gigabytes.
///
/// Cluster membership is stored as plain identifiers rather than SwiftData relationships:
/// at this row count the relationship graph is the single most expensive thing SwiftData
/// does, and every lookup this app performs is a filtered fetch anyway.
@Model
final class AssetRecord {
    #Unique<AssetRecord>([\.localIdentifier])
    #Index<AssetRecord>([\.creationDate], [\.localIdentifier])

    // MARK: Identity and Stage 1 metadata

    var localIdentifier: String = ""
    var creationDate: Date = Date.distantPast
    var modificationDate: Date?
    var mediaTypeRaw: Int = 0
    var mediaSubtypesRaw: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var duration: Double = 0
    var isFavoriteInPhotos: Bool = false
    var burstIdentifier: String?
    var latitude: Double?
    var longitude: Double?

    /// False when the original lives only in iCloud. Indexing never downloads it, so such
    /// assets are still catalogued from metadata but are skipped by the pixel stages.
    var isLocallyAvailable: Bool = true

    // MARK: Computed by the analysis pipeline

    /// Bumped when the pipeline's meaning changes, so old rows can be re-analyzed selectively.
    var analysisVersion: Int = 0
    var featurePrint: Data?
    var aestheticsScore: Double?
    var faceQuality: Double?
    var faceCount: Int = 0
    var sharpness: Double?
    var averageColor: Int = 0

    /// Vision's judgement that this is a document, receipt or saved image rather than a
    /// photograph. It is the only signal available for "this arrived here, it wasn't taken
    /// here", which is what the Include Downloads setting really means.
    var isUtilityImage: Bool = false

    /// The blended Memory Quality Score. Internal ranking only — never surfaced as a number.
    var memoryScore: Double = 0

    var similarityClusterID: UUID?
    var isBestInSimilarityCluster: Bool = true
    var eventClusterID: UUID?

    // MARK: User state

    /// "Hide from Memories". Explicitly not a delete: the asset stays untouched in Photos and
    /// can be restored from the Hidden Memories screen.
    var excludedFromMemories: Bool = false
    var isLoved: Bool = false
    var shownCount: Int = 0
    var lastShownAt: Date?

    init(localIdentifier: String, creationDate: Date) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
    }
}

// MARK: - Derived properties

extension AssetRecord {
    var mediaType: PHAssetMediaType { PHAssetMediaType(rawValue: mediaTypeRaw) ?? .unknown }
    var mediaSubtypes: PHAssetMediaSubtype { PHAssetMediaSubtype(rawValue: UInt(mediaSubtypesRaw)) }

    var isVideo: Bool { mediaType == .video }
    var isPhoto: Bool { mediaType == .image }
    var isScreenshot: Bool { mediaSubtypes.contains(.photoScreenshot) }
    var isLivePhoto: Bool { mediaSubtypes.contains(.photoLive) }
    var isScreenRecording: Bool { isVideo && mediaSubtypes.contains(.videoHighFrameRate) == false && duration > 0 && isScreenshotLikeVideo }
    var isPanorama: Bool { mediaSubtypes.contains(.photoPanorama) }

    /// Screen recordings carry no dedicated subtype, so they are inferred from the exact
    /// screen aspect ratio plus the absence of any capture metadata.
    private var isScreenshotLikeVideo: Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        return latitude == nil && aspectRatioLooksLikeScreen
    }

    private var aspectRatioLooksLikeScreen: Bool {
        let ratio = Double(max(pixelWidth, pixelHeight)) / Double(min(pixelWidth, pixelHeight))
        return abs(ratio - 19.5 / 9.0) < 0.03 || abs(ratio - 16.0 / 9.0) < 0.02
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    /// Everything the curator is allowed to consider for an emotional memory.
    var isMemoryEligible: Bool {
        !excludedFromMemories && isLocallyAvailable && isBestInSimilarityCluster
    }
}
