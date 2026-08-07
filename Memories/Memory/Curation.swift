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
    /// Images that arrived rather than were taken — saved pictures, receipts, documents.
    var includeDownloads = false
    /// Assets whose originals live only in iCloud. They are kept out of *memories*, because
    /// a memory whose pictures cannot be shown is not a memory — but they must still appear
    /// when browsing, or a library on Optimize iPhone Storage would look mostly empty.
    var includeCloudOnly = false
    /// Hidden means hidden from Memories, never deleted. Only the Hidden screen sets this.
    var includeHiddenFromMemories = false
    /// How much of a memory may be video. Browsing ignores it — a filter that quietly withheld
    /// clips from the Videos screen would be a bug, not a preference.
    var videoMix: VideoMix = .balanced

    static let feed = CurationOptions()
    static let browsing = CurationOptions(mode: .pure, includeScreenshots: true,
                                          includeScreenRecordings: true,
                                          includeDownloads: true,
                                          includeCloudOnly: true)
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
                predicate: #Predicate { $0.momentDate >= start && $0.momentDate < end },
                sortBy: [SortDescriptor(\.momentDate, order: .forward)]
            )
            if let limitPerInterval { descriptor.fetchLimit = limitPerInterval * 4 }

            guard let fetched = try? context.fetch(descriptor) else { continue }
            var filtered = fetched.filter { passes($0, options: options) }
            if let limitPerInterval, filtered.count > limitPerInterval {
                filtered = Array(filtered.prefix(limitPerInterval))
            }
            results.append(contentsOf: filtered)
        }
        return results.sorted { $0.momentDate < $1.momentDate }
    }

    static func passes(_ record: AssetRecord, options: CurationOptions) -> Bool {
        if !options.includeHiddenFromMemories && record.excludedFromMemories { return false }
        if !options.includeCloudOnly && !record.isLocallyAvailable { return false }

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

    /// Rows for a known set of identifiers, in library order.
    static func records(for identifiers: [String], context: ModelContext) -> [AssetRecord] {
        guard !identifiers.isEmpty else { return [] }
        let wanted = identifiers
        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { wanted.contains($0.localIdentifier) },
            sortBy: [SortDescriptor(\.momentDate, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func allRecords(context: ModelContext,
                           newestFirst: Bool = true,
                           limit: Int? = nil) -> [AssetRecord] {
        var descriptor = FetchDescriptor<AssetRecord>(
            sortBy: [SortDescriptor(\.momentDate, order: newestFirst ? .reverse : .forward)]
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

        // 2b. Saved images rather than taken ones.
        //
        // iOS exposes no "this was downloaded" flag, so the only available signal is
        // Vision's judgement that a frame is a document or graphic rather than a
        // photograph. That judgement is a guess, so it filters here — inside the same
        // safeguard that stops a memory being emptied — instead of in `passes`, where a
        // wrong guess would make a photo vanish from the whole app.
        if !options.includeDownloads {
            let taken = kept.filter { !$0.isUtilityImage }
            if taken.count >= max(3, kept.count / 3) { kept = taken }
        }

        // 3. Stop one burst of shooting from becoming the whole memory.
        kept = limitClusterDominance(kept)

        // 4. Hold video to the share the user asked for, in both directions: trim it back when
        //    a day of filming would otherwise crowd out the photographs, and put the best clip
        //    back when quality scoring buried every one of them. A clip carries a moment stills
        //    cannot, which is why the floor exists at all.
        kept = limitVideoShare(kept, to: options.videoMix)
        if options.videoMix.reinstatesOne {
            kept = reinstateVideo(from: assets, into: kept)
        }

        return kept.sorted { $0.momentDate < $1.momentDate }
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

    /// Trims video down to its allowed share, keeping the best clips.
    ///
    /// The ceiling is measured against the photographs rather than against the whole memory, so
    /// that dropping a clip cannot lower the allowance and cause another to be dropped. An
    /// occasion that is *only* video is left alone: the alternative is an empty memory.
    private static func limitVideoShare(_ kept: [AssetRecord], to mix: VideoMix) -> [AssetRecord] {
        let videos = kept.filter(\.isVideo)
        let stills = kept.count - videos.count
        guard stills > 0, !videos.isEmpty else { return kept }

        let allowed = max(mix.reinstatesOne ? 1 : 0,
                          Int((Double(stills) * mix.ceiling).rounded()))
        guard videos.count > allowed else { return kept }

        let survivors = Set(videos.sorted { $0.memoryScore > $1.memoryScore }
                                  .prefix(allowed)
                                  .map(\.localIdentifier))
        return kept.filter { !$0.isVideo || survivors.contains($0.localIdentifier) }
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
