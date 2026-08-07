import Foundation
import SwiftData

/// Whether the app is allowed to have an opinion about what you see.
enum CurationMode: String, Codable, CaseIterable, Sendable {
    /// Everything in the window, in order, untouched. What actually happened.
    case pure
    /// The same window, curated: duplicates collapsed to their best frame, weak shots held
    /// back, video and stills balanced, and no single burst allowed to swallow the memory.
    case smart

    var title: String { self == .pure ? "Pure" : "Smart" }
}

enum MediaFilter: String, CaseIterable, Sendable {
    case all, photos, videos, livePhotos, screenshots

    var title: String {
        switch self {
        case .all:         return "All"
        case .photos:      return "Photos"
        case .videos:      return "Videos"
        case .livePhotos:  return "Live Photos"
        case .screenshots: return "Screenshots"
        }
    }
}

struct CurationOptions: Sendable, Equatable {
    var mode: CurationMode = .smart
    var media: MediaFilter = .all
    /// Screenshots stay out of emotional memories by default; they have their own section
    /// and their own switch in Settings.
    var includeScreenshots = false
    var includeScreenRecordings = false
    /// Hidden means hidden from Memories, never deleted. Only the Hidden screen sets this.
    var includeHiddenFromMemories = false

    static let feed = CurationOptions()
    static let browsing = CurationOptions(mode: .pure, includeScreenshots: true,
                                          includeScreenRecordings: true)
}

// MARK: - Fetching

enum LibraryQuery {

    /// Assets inside a set of time spans.
    ///
    /// Each span is fetched separately rather than fetching one huge range and filtering,
    /// because "this week through the years" is fifteen small indexed reads instead of one
    /// scan across a decade.
    static func assets(in intervals: [DateInterval],
                       options: CurationOptions,
                       context: ModelContext,
                       limitPerInterval: Int? = nil) -> [AssetRecord] {
        var results: [AssetRecord] = []

        for interval in intervals {
            let start = interval.start
            let end = interval.end
            var descriptor = FetchDescriptor<AssetRecord>(
                predicate: #Predicate { $0.creationDate >= start && $0.creationDate < end },
                sortBy: [SortDescriptor(\.creationDate, order: .forward)]
            )
            if let limitPerInterval { descriptor.fetchLimit = limitPerInterval * 4 }

            guard let fetched = try? context.fetch(descriptor) else { continue }
            var filtered = fetched.filter { passes($0, options: options) }
            if let limitPerInterval, filtered.count > limitPerInterval {
                filtered = Array(filtered.prefix(limitPerInterval))
            }
            results.append(contentsOf: filtered)
        }
        return results.sorted { $0.creationDate < $1.creationDate }
    }

    static func passes(_ record: AssetRecord, options: CurationOptions) -> Bool {
        if !options.includeHiddenFromMemories && record.excludedFromMemories { return false }
        if !record.isLocallyAvailable { return false }

        switch options.media {
        case .all:
            if !options.includeScreenshots && record.isScreenshot { return false }
            if !options.includeScreenRecordings && record.isScreenRecording { return false }
        case .photos:
            guard record.isPhoto else { return false }
            if !options.includeScreenshots && record.isScreenshot { return false }
        case .videos:
            guard record.isVideo else { return false }
        case .livePhotos:
            guard record.isLivePhoto else { return false }
        case .screenshots:
            guard record.isScreenshot else { return false }
        }
        return true
    }

    static func allRecords(context: ModelContext,
                           newestFirst: Bool = true,
                           limit: Int? = nil) -> [AssetRecord] {
        var descriptor = FetchDescriptor<AssetRecord>(
            sortBy: [SortDescriptor(\.creationDate, order: newestFirst ? .reverse : .forward)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }
}

// MARK: - Curating

enum Curator {

    /// Weak enough that it was probably a mistake rather than a memory.
    static let weakThreshold: Double = 0.38
    /// Nothing may take more than this share of a memory, however much of it you shot.
    static let maxShareOfOneCluster: Double = 0.25

    static func curate(_ assets: [AssetRecord], options: CurationOptions) -> [AssetRecord] {
        guard options.mode == .smart else { return assets }
        guard assets.count > 3 else { return assets }

        // 1. One frame per similarity group — the elected best shot.
        var kept = assets.filter(\.isBestInSimilarityCluster)
        if kept.isEmpty { kept = assets }

        // 2. Drop the weak, but never empty the memory doing it.
        let strong = kept.filter { $0.memoryScore >= weakThreshold }
        if strong.count >= max(3, kept.count / 4) { kept = strong }

        // 3. Stop one burst of shooting from becoming the whole memory.
        kept = limitClusterDominance(kept)

        // 4. Keep at least one video if the occasion had any: a clip carries a moment that
        //    stills cannot, and quality scoring alone tends to bury them.
        kept = reinstateVideo(from: assets, into: kept)

        return kept.sorted { $0.creationDate < $1.creationDate }
    }

    private static func limitClusterDominance(_ assets: [AssetRecord]) -> [AssetRecord] {
        let cap = max(3, Int(Double(assets.count) * maxShareOfOneCluster))
        var perEvent: [UUID: Int] = [:]
        var result: [AssetRecord] = []

        for asset in assets.sorted(by: { $0.memoryScore > $1.memoryScore }) {
            if let event = asset.eventClusterID {
                let count = perEvent[event, default: 0]
                guard count < cap else { continue }
                perEvent[event] = count + 1
            }
            result.append(asset)
        }
        return result
    }

    private static func reinstateVideo(from source: [AssetRecord],
                                       into kept: [AssetRecord]) -> [AssetRecord] {
        guard !kept.contains(where: \.isVideo),
              let best = source.filter(\.isVideo).max(by: { $0.memoryScore < $1.memoryScore })
        else { return kept }
        return kept + [best]
    }

    /// The frame that should represent a set. Quality decides, but a frame with a
    /// well-captured face wins a close call — that is what people remember.
    static func cover(for assets: [AssetRecord]) -> AssetRecord? {
        assets.max { lhs, rhs in
            let lhsScore = lhs.memoryScore + (lhs.faceQuality ?? 0) * 0.15
            let rhsScore = rhs.memoryScore + (rhs.faceQuality ?? 0) * 0.15
            return lhsScore < rhsScore
        }
    }
}
