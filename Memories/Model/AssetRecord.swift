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
    #Index<AssetRecord>([\.momentDate], [\.creationDate], [\.localIdentifier])

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

    // MARK: Where it came from

    var originalFilename: String?
    /// `SourcePlatform.rawValue`. Inferred, never certain — see `ProvenanceReader`.
    var sourceRaw: String?

    /// When the footage was actually recorded, recovered from the video container or from a
    /// messaging app's filename, and only set when it disagrees with what Photos holds.
    ///
    /// Photos records when something entered *your library*. For anything saved from another
    /// app that is the day you saved it, so a clip from a holiday three years ago would
    /// otherwise surface as if it happened last week.
    var capturedDate: Date?

    /// The date this actually happened: `capturedDate` when one was recovered, otherwise the
    /// library's own. **Everything that arranges the library by time reads this**, not
    /// `creationDate`.
    ///
    /// Stored rather than computed on purpose. A computed property cannot appear in a
    /// SwiftData predicate or sort descriptor, so a corrected date would have changed only
    /// the label on the viewer while On This Day, Timeline and Calendar carried on filing the
    /// clip under the day it was saved — a correction that corrected nothing.
    var momentDate: Date = Date.distantPast

    // MARK: Computed by the analysis pipeline

    /// Bumped when the pipeline's meaning changes, so old rows can be re-analyzed selectively.
    var analysisVersion: Int = 0
    var featurePrint: Data?
    var aestheticsScore: Double?
    var faceQuality: Double?
    var faceCount: Int = 0
    var sharpness: Double?

    /// Saliency, kept alongside the other measurements so the rescoring pass that runs after
    /// clustering can reuse them without going back to the pixels.
    var composition: Double?
    var subjectProminence: Double?

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

    /// Set because somebody in this photograph has been hidden, not because the photograph has.
    ///
    /// Kept apart from `excludedFromMemories` on purpose. They mean different things and they
    /// are undone by different actions: bringing a person back must not un-hide a photograph
    /// the user hid by hand, and un-hiding that photograph must not bring the person back. One
    /// flag would have to guess which of the two the user meant.
    ///
    /// It is stored rather than worked out at read time because the curator asks this question
    /// of tens of thousands of rows on every pass, and answering it live would mean loading
    /// every hidden person's asset list into every one of those passes.
    var hiddenByPerson: Bool = false

    var isLoved: Bool = false
    var shownCount: Int = 0
    var lastShownAt: Date?

    init(localIdentifier: String, creationDate: Date) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.momentDate = creationDate
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
    var isPanorama: Bool { mediaSubtypes.contains(.photoPanorama) }

    /// Screen recordings carry no dedicated Photos subtype, so this leans on Vision's own
    /// judgement that the frame is an interface rather than a scene.
    ///
    /// The obvious alternative — matching the display's aspect ratio — was worse: it swept
    /// up most 16:9 and 19.5:9 footage without location metadata, which is to say most
    /// drone, action-camera and imported video, and quietly kept it out of memories.
    var isScreenRecording: Bool { isVideo && isUtilityImage }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    /// Everything the curator is allowed to consider for an emotional memory.
    var isMemoryEligible: Bool {
        !excludedFromMemories && !hiddenByPerson && isLocallyAvailable && isBestInSimilarityCluster
    }

    var source: SourcePlatform? { sourceRaw.flatMap(SourcePlatform.init(rawValue:)) }

    /// Bring `momentDate` back in line after either date it derives from has changed.
    func refreshMomentDate() {
        momentDate = capturedDate ?? creationDate
    }

    /// True when the two disagree by more than a day — worth telling the user about, because
    /// it explains why something old is being shown as if it were recent.
    var hasCorrectedDate: Bool {
        guard let capturedDate else { return false }
        return abs(capturedDate.timeIntervalSince(creationDate)) > 86_400
    }
}
