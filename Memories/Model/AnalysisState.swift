import Foundation
import SwiftData

/// The six passes over the library, cheapest first, so the app is useful long before it is finished.
enum AnalysisStage: String, Codable, CaseIterable, Sendable {
    case metadata      // ids, dates, kinds, dimensions, location — Timeline works after this
    case thumbnails    // warm the cache the grids read from
    case similarity    // Vision feature prints, then clustering
    case quality       // aesthetics and face capture quality
    case events        // group shooting sessions into occasions
    case memories      // build and score candidates

    var title: String {
        switch self {
        case .metadata:   return "Reading your library"
        case .thumbnails: return "Preparing previews"
        case .similarity: return "Finding repeats"
        case .quality:    return "Judging shots"
        case .events:     return "Grouping occasions"
        case .memories:   return "Assembling memories"
        }
    }
}

/// Everything needed to resume indexing rather than restart it.
///
/// Re-analyzing 100k assets on every launch would be indefensible, so the library is diffed
/// against what is already recorded and only the difference is processed.
@Model
final class AnalysisState {
    #Unique<AnalysisState>([\.id])

    /// Singleton row.
    var id: String = "state"

    /// Bumped in code when a stage's meaning changes; rows below this are recomputed.
    var analysisVersion: Int = 0

    var indexedCount: Int = 0
    var lastIndexStartedAt: Date?
    var lastIndexFinishedAt: Date?

    /// 0...1 per `AnalysisStage.rawValue`.
    var stageProgress: [String: Double] = [:]
    var currentStageRaw: String?

    /// Counts from the most recent incremental pass, shown in Settings.
    var lastDeltaInserted: Int = 0
    var lastDeltaRemoved: Int = 0
    var lastDeltaModified: Int = 0

    /// Set when the heavy passes stepped back because the device was hot or low on battery.
    var isPausedForDeviceConditions: Bool = false

    var thumbnailCacheBytes: Int = 0
    var analysisCacheBytes: Int = 0

    init() {}

    var currentStage: AnalysisStage? {
        currentStageRaw.flatMap(AnalysisStage.init(rawValue:))
    }

    var overallProgress: Double {
        guard !AnalysisStage.allCases.isEmpty else { return 0 }
        let total = AnalysisStage.allCases.reduce(0.0) { $0 + (stageProgress[$1.rawValue] ?? 0) }
        return total / Double(AnalysisStage.allCases.count)
    }

    var hasUsableIndex: Bool { (stageProgress[AnalysisStage.metadata.rawValue] ?? 0) >= 1 }
}

/// What the app has learned about this user, locally, from what they actually do.
///
/// Deliberately a handful of readable numbers rather than an opaque model: it can be
/// explained in one screen and erased with one button.
@Model
final class UserPreference {
    #Unique<UserPreference>([\.id])

    var id: String = "preferences"

    /// Each nudges ranking by a small amount and is clamped, so no single habit can take over.
    var videoAffinity: Double = 0
    var screenshotAffinity: Double = 0
    var peopleAffinity: Double = 0
    var placeAffinity: Double = 0
    var recentPastAffinity: Double = 0
    var distantPastAffinity: Double = 0

    /// Per-`MemoryKind` adjustment, keyed by raw value.
    var kindAffinity: [String: Double] = [:]

    var savedCount: Int = 0
    var dismissedCount: Int = 0
    var openedCount: Int = 0
    var lastUpdatedAt: Date = Date.now

    init() {}

    static let bound = 0.35

    func nudge(_ keyPath: ReferenceWritableKeyPath<UserPreference, Double>, by delta: Double) {
        self[keyPath: keyPath] = min(Self.bound, max(-Self.bound, self[keyPath: keyPath] + delta))
        lastUpdatedAt = .now
    }

    func nudgeKind(_ kind: MemoryKind, by delta: Double) {
        let current = kindAffinity[kind.rawValue] ?? 0
        kindAffinity[kind.rawValue] = min(Self.bound, max(-Self.bound, current + delta))
        lastUpdatedAt = .now
    }

    func reset() {
        videoAffinity = 0
        screenshotAffinity = 0
        peopleAffinity = 0
        placeAffinity = 0
        recentPastAffinity = 0
        distantPastAffinity = 0
        kindAffinity = [:]
        savedCount = 0
        dismissedCount = 0
        openedCount = 0
        lastUpdatedAt = .now
    }
}
