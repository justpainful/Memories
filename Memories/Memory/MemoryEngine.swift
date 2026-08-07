import Foundation
import SwiftData

/// Builds the feed.
///
/// Not a list of filters. Every generator proposes candidates independently, each candidate
/// is scored on the same seven components, and the feed is what survives — which is why the
/// page is different tomorrow without anyone scheduling it to be.
@ModelActor
actor MemoryEngine {

    private static let maxFeedLength = 9

    /// The most that video, faces and screenshots together may move a candidate.
    private static let compositionLimit = 0.12

    // MARK: Entry point

    func buildFeed(reference: Date = .now,
                   options: CurationOptions = .feed,
                   limit: Int = maxFeedLength) -> [MemoryCandidate] {
        var candidates: [MemoryCandidate] = []
        candidates += onThisDay(reference, options)
        candidates += thisWeekThroughYears(reference, options)
        candidates += recentWindow(reference, options)
        candidates += notableEvents(reference, options)
        candidates += bestOfMonth(reference, options)
        candidates += bestOfYear(reference, options)
        candidates += season(reference, options)
        candidates += forgotten(reference, options)
        candidates += rediscovery(reference, options)
        candidates += places(reference, options)
        candidates += smartRandom(reference, options)

        let preference = modelContext.userPreference
        var scored = candidates.map { candidate -> MemoryCandidate in
            var copy = candidate
            copy.components.recentExposure = exposure(for: candidate.id, reference: reference)
            copy.score = copy.components.total
                + preferenceAdjustment(for: candidate, preference, options: options)
            return copy
        }

        scored.sort { $0.score > $1.score }
        return diversify(scored, limit: limit)
    }

    /// Don't hand back nine variations of the same idea just because they all scored well.
    private func diversify(_ candidates: [MemoryCandidate], limit: Int) -> [MemoryCandidate] {
        var chosen: [MemoryCandidate] = []
        var kindCount: [MemoryKind: Int] = [:]
        var usedAssets = Set<String>()

        for candidate in candidates {
            guard chosen.count < limit else { break }
            guard kindCount[candidate.kind, default: 0] < 2 else { continue }

            // Skip anything that is mostly made of frames already on screen.
            let overlap = candidate.assetIdentifiers.filter(usedAssets.contains).count
            let overlapShare = Double(overlap) / Double(max(1, candidate.assetCount))
            guard overlapShare < 0.5 else { continue }

            chosen.append(candidate)
            kindCount[candidate.kind, default: 0] += 1
            usedAssets.formUnion(candidate.assetIdentifiers)
        }
        return chosen
    }

    // MARK: Generators

    private func onThisDay(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        let calendar = Calendar.current
        var results: [MemoryCandidate] = []

        for interval in TimeWindow.onThisDay.intervals(reference: reference) {
            let raw = LibraryQuery.assets(in: [interval], options: options, context: modelContext)
            let assets = Curator.curate(raw, options: options)
            guard assets.count >= 2 else { continue }

            let years = calendar.dateComponents([.year], from: interval.start, to: reference).year ?? 0
            guard years > 0 else { continue }

            var components = ScoreComponents()
            components.relevance = 1.0
            components.quality = averageQuality(assets)
            components.novelty = novelty(assets, reference: reference)
            components.timeSignificance = anniversaryWeight(years)
            components.mediaDiversity = diversity(assets)
            components.duplicateDensity = duplicateDensity(raw, curated: assets)

            results.append(MemoryCandidate(
                id: "onThisDay-\(calendar.component(.year, from: interval.start))",
                kind: .onThisDay,
                title: years == 1 ? "A year ago today" : "\(years) years ago today",
                subtitle: subtitle(for: assets, at: interval.start),
                referenceDate: interval.start,
                assetIdentifiers: assets.map(\.localIdentifier),
                coverIdentifier: Curator.cover(for: assets)?.localIdentifier,
                components: components
            ))
        }
        return results
    }

    private func thisWeekThroughYears(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        let calendar = Calendar.current
        let intervals = TimeWindow.thisWeekInPreviousYears.intervals(reference: reference, yearsBack: 8)

        var perYear: [Int: [AssetRecord]] = [:]
        for interval in intervals {
            let raw = LibraryQuery.assets(in: [interval], options: options,
                                          context: modelContext, limitPerInterval: 40)
            let assets = Curator.curate(raw, options: options)
            guard assets.count >= 2 else { continue }
            perYear[calendar.component(.year, from: interval.start)] = assets
        }
        guard perYear.count >= 2 else { return [] }

        let all = perYear.values.flatMap { $0 }
        var components = ScoreComponents()
        components.relevance = 0.86
        components.quality = averageQuality(all)
        components.novelty = novelty(all, reference: reference)
        components.timeSignificance = min(1, Double(perYear.count) / 5)
        components.mediaDiversity = diversity(all)

        return [MemoryCandidate(
            id: "weekThroughYears-\(calendar.component(.weekOfYear, from: reference))",
            kind: .previousYears,
            title: "This week through the years",
            subtitle: "\(perYear.count) years",
            referenceDate: reference,
            assetIdentifiers: all.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: all)?.localIdentifier,
            components: components
        )]
    }

    private func recentWindow(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        let raw = LibraryQuery.assets(in: TimeWindow.thisWeek.intervals(reference: reference),
                                      options: options, context: modelContext)
        let assets = Curator.curate(raw, options: options)
        guard assets.count >= 4 else { return [] }

        var components = ScoreComponents()
        components.relevance = 0.55
        components.quality = averageQuality(assets)
        components.novelty = 0.3     // recent frames are barely a rediscovery
        components.mediaDiversity = diversity(assets)
        components.duplicateDensity = duplicateDensity(raw, curated: assets)

        return [MemoryCandidate(
            id: "thisWeek-\(Calendar.current.component(.weekOfYear, from: reference))",
            kind: .thisWeek,
            title: "This week",
            subtitle: "\(assets.count) moments",
            referenceDate: reference,
            assetIdentifiers: assets.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: assets)?.localIdentifier,
            components: components
        )]
    }

    private func notableEvents(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        var descriptor = FetchDescriptor<EventCluster>(
            sortBy: [SortDescriptor(\.significance, order: .reverse)]
        )
        descriptor.fetchLimit = 14
        guard let events = try? modelContext.fetch(descriptor) else { return [] }

        return events.prefix(6).compactMap { event -> MemoryCandidate? in
            let assets = Curator.curate(records(for: event.assetIdentifiers, options: options),
                                        options: options)
            guard assets.count >= 4 else { return nil }

            let age = reference.timeIntervalSince(event.startDate) / 86_400
            guard age > 20 else { return nil }   // last month is not yet a memory

            var components = ScoreComponents()
            components.relevance = event.significance
            components.quality = averageQuality(assets)
            components.novelty = novelty(assets, reference: reference)
            components.timeSignificance = min(1, age / 900)
            components.mediaDiversity = diversity(assets)

            return MemoryCandidate(
                id: "event-\(event.id.uuidString)",
                kind: .event,
                title: eventTitle(for: event, assets: assets),
                subtitle: "\(assets.count) moments",
                referenceDate: event.startDate,
                assetIdentifiers: assets.map(\.localIdentifier),
                coverIdentifier: event.coverIdentifier ?? Curator.cover(for: assets)?.localIdentifier,
                eventID: event.id,
                placeName: event.placeName,
                components: components
            )
        }
    }

    private func bestOfMonth(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        let calendar = Calendar.current
        guard let lastYear = calendar.date(byAdding: .year, value: -1, to: reference) else { return [] }

        let raw = LibraryQuery.assets(in: [calendar.monthInterval(for: lastYear)],
                                      options: options, context: modelContext)
        let best = Array(Curator.curate(raw, options: options)
            .sorted { $0.memoryScore > $1.memoryScore }
            .prefix(12))
        guard best.count >= 4 else { return [] }

        var components = ScoreComponents()
        components.relevance = 0.6
        components.quality = averageQuality(best)
        components.novelty = novelty(best, reference: reference)
        components.timeSignificance = 0.55
        components.mediaDiversity = diversity(best)

        return [MemoryCandidate(
            id: "bestOfMonth-\(calendar.component(.year, from: lastYear))-\(calendar.component(.month, from: lastYear))",
            kind: .bestOfMonth,
            title: lastYear.formatted(.dateTime.month(.wide).year()),
            subtitle: "\(best.count) moments",
            referenceDate: lastYear,
            assetIdentifiers: best.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: best)?.localIdentifier,
            components: components
        )]
    }

    private func bestOfYear(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: reference) - 1
        guard let interval = calendar.interval(year: year) else { return [] }

        let raw = LibraryQuery.assets(in: [interval], options: options,
                                      context: modelContext, limitPerInterval: 600)
        let best = Array(Curator.curate(raw, options: options)
            .sorted { $0.memoryScore > $1.memoryScore }
            .prefix(16))
        guard best.count >= 6 else { return [] }

        var components = ScoreComponents()
        components.relevance = 0.5
        components.quality = averageQuality(best)
        components.novelty = novelty(best, reference: reference)
        components.timeSignificance = 0.7
        components.mediaDiversity = diversity(best)

        return [MemoryCandidate(
            id: "bestOfYear-\(year)",
            kind: .bestOfYear,
            title: "The best of \(year)",
            subtitle: "\(best.count) moments",
            referenceDate: interval.start,
            assetIdentifiers: best.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: best)?.localIdentifier,
            components: components
        )]
    }

    private func season(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        let intervals = TimeWindow.thisSeasonInPreviousYears.intervals(reference: reference, yearsBack: 6)
        let raw = LibraryQuery.assets(in: intervals, options: options,
                                      context: modelContext, limitPerInterval: 30)
        let assets = Array(Curator.curate(raw, options: options)
            .sorted { $0.memoryScore > $1.memoryScore }
            .prefix(14))
        guard assets.count >= 5 else { return [] }

        var components = ScoreComponents()
        components.relevance = 0.48
        components.quality = averageQuality(assets)
        components.novelty = novelty(assets, reference: reference)
        components.timeSignificance = 0.45
        components.mediaDiversity = diversity(assets)

        return [MemoryCandidate(
            id: "season-\(Calendar.current.component(.month, from: reference) / 3)",
            kind: .season,
            title: "This season, before",
            subtitle: "\(assets.count) moments",
            referenceDate: reference,
            assetIdentifiers: assets.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: assets)?.localIdentifier,
            components: components
        )]
    }

    /// Good photographs that have not been in front of you for a long time.
    private func forgotten(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        guard let cutoff = Calendar.current.date(byAdding: .year, value: -2, to: reference) else { return [] }
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.creationDate < cutoff && $0.memoryScore > 0.62 },
            sortBy: [SortDescriptor(\.memoryScore, order: .reverse)]
        )
        descriptor.fetchLimit = 220
        guard let pool = try? modelContext.fetch(descriptor) else { return [] }

        let unseen = pool
            .filter { LibraryQuery.passes($0, options: options) && $0.isBestInSimilarityCluster }
            .filter { $0.shownCount == 0 || ($0.lastShownAt.map { reference.timeIntervalSince($0) > 180 * 86_400 } ?? true) }
        let assets = Array(unseen.prefix(12))
        guard assets.count >= 5 else { return [] }

        var components = ScoreComponents()
        components.relevance = 0.44
        components.quality = averageQuality(assets)
        components.novelty = 1.0
        components.timeSignificance = 0.5
        components.mediaDiversity = diversity(assets)

        return [MemoryCandidate(
            id: "forgotten-\(Calendar.current.component(.dayOfYear, from: reference))",
            kind: .forgotten,
            title: "You haven't seen these in a while",
            subtitle: "\(assets.count) moments",
            referenceDate: assets.first?.creationDate ?? reference,
            assetIdentifiers: assets.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: assets)?.localIdentifier,
            components: components
        )]
    }

    /// Things you went back to recently — worth continuing rather than dropping.
    private func rediscovery(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        guard let since = Calendar.current.date(byAdding: .day, value: -14, to: reference) else { return [] }
        // Filtered on `shownCount` rather than the optional date, then narrowed in memory:
        // optional comparisons inside a predicate are more trouble than the fetch saves.
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.shownCount > 0 },
            sortBy: [SortDescriptor(\.memoryScore, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        guard let shown = try? modelContext.fetch(descriptor) else { return [] }
        let recent = shown.filter { ($0.lastShownAt ?? .distantPast) >= since }
        guard recent.count >= 6 else { return [] }

        // Not the frames themselves — their neighbours in time, which you have not seen.
        var neighbours: [AssetRecord] = []
        for anchor in recent.prefix(6) {
            let day = Calendar.current.dayInterval(for: anchor.creationDate)
            let sameDay = LibraryQuery.assets(in: [day], options: options, context: modelContext)
            neighbours += sameDay.filter { $0.shownCount == 0 && $0.memoryScore > 0.5 }
        }
        let assets = Array(Set(neighbours.map(\.localIdentifier)))
            .compactMap { identifier in neighbours.first { $0.localIdentifier == identifier } }
            .sorted { $0.memoryScore > $1.memoryScore }
            .prefix(10)
        guard assets.count >= 4 else { return [] }

        var components = ScoreComponents()
        components.relevance = 0.42
        components.quality = averageQuality(Array(assets))
        components.novelty = 0.9
        components.mediaDiversity = diversity(Array(assets))

        return [MemoryCandidate(
            id: "rediscovery-\(Calendar.current.component(.weekOfYear, from: reference))",
            kind: .rediscovery,
            title: "More from what you revisited",
            subtitle: "\(assets.count) moments",
            referenceDate: assets.first?.creationDate ?? reference,
            assetIdentifiers: assets.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: Array(assets))?.localIdentifier,
            components: components
        )]
    }

    private func places(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        var descriptor = FetchDescriptor<EventCluster>(
            sortBy: [SortDescriptor(\.significance, order: .reverse)]
        )
        descriptor.fetchLimit = 40
        guard let events = try? modelContext.fetch(descriptor) else { return [] }

        let located = events.filter { $0.latitude != nil && $0.placeName != nil }
        guard let event = located.first else { return [] }

        let assets = Curator.curate(records(for: event.assetIdentifiers, options: options),
                                    options: options)
        guard assets.count >= 4 else { return [] }

        var components = ScoreComponents()
        components.relevance = 0.46
        components.quality = averageQuality(assets)
        components.novelty = novelty(assets, reference: reference)
        components.mediaDiversity = diversity(assets)

        return [MemoryCandidate(
            id: "place-\(event.id.uuidString)",
            kind: .place,
            title: event.placeName ?? "Somewhere you know",
            subtitle: "\(assets.count) moments",
            referenceDate: event.startDate,
            assetIdentifiers: assets.map(\.localIdentifier),
            coverIdentifier: event.coverIdentifier,
            eventID: event.id,
            placeName: event.placeName,
            components: components
        )]
    }

    /// Random, but not blind: no screenshots, no duplicates, nothing weak, and nothing you
    /// were just shown.
    private func smartRandom(_ reference: Date, _ options: CurationOptions) -> [MemoryCandidate] {
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.memoryScore > 0.55 },
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        descriptor.fetchLimit = 900
        guard let pool = try? modelContext.fetch(descriptor) else { return [] }

        let eligible = pool.filter {
            LibraryQuery.passes($0, options: options)
                && $0.isBestInSimilarityCluster
                && ($0.lastShownAt.map { reference.timeIntervalSince($0) > 7 * 86_400 } ?? true)
        }
        guard eligible.count >= 8 else { return [] }

        // Seeded by the day so the feed is stable if you close and reopen the app, and
        // different tomorrow.
        var generator = SeededGenerator(seed: UInt64(Calendar.current.component(.dayOfYear, from: reference)))
        let assets = Array(eligible.shuffled(using: &generator).prefix(9))

        var components = ScoreComponents()
        components.relevance = 0.34
        components.quality = averageQuality(assets)
        components.novelty = 0.8
        components.mediaDiversity = diversity(assets)

        return [MemoryCandidate(
            id: "random-\(Calendar.current.component(.dayOfYear, from: reference))",
            kind: .random,
            title: "From somewhere in your library",
            subtitle: "\(assets.count) moments",
            referenceDate: assets.first?.creationDate ?? reference,
            assetIdentifiers: assets.map(\.localIdentifier),
            coverIdentifier: Curator.cover(for: assets)?.localIdentifier,
            components: components
        )]
    }

    // MARK: Scoring helpers

    /// Indexed on `localIdentifier` rather than fetching the whole table and filtering it.
    /// The feed calls this once per candidate, so at library scale the difference between a
    /// predicate and a full pass is the difference between a feed and a stall.
    private func records(for identifiers: [String], options: CurationOptions) -> [AssetRecord] {
        LibraryQuery.records(for: identifiers, context: modelContext)
            .filter { LibraryQuery.passes($0, options: options) }
    }

    private func averageQuality(_ assets: [AssetRecord]) -> Double {
        guard !assets.isEmpty else { return 0 }
        return assets.map(\.memoryScore).reduce(0, +) / Double(assets.count)
    }

    private func diversity(_ assets: [AssetRecord]) -> Double {
        guard !assets.isEmpty else { return 0 }
        let videos = assets.filter(\.isVideo).count
        let share = Double(videos) / Double(assets.count)
        return share == 0 ? 0.2 : 1 - abs(share - 0.25) * 2
    }

    private func duplicateDensity(_ raw: [AssetRecord], curated: [AssetRecord]) -> Double {
        guard !raw.isEmpty else { return 0 }
        return 1 - Double(curated.count) / Double(raw.count)
    }

    private func novelty(_ assets: [AssetRecord], reference: Date) -> Double {
        guard !assets.isEmpty else { return 0 }
        let scores = assets.map { asset -> Double in
            guard let last = asset.lastShownAt else { return 1 }
            let days = reference.timeIntervalSince(last) / 86_400
            return min(1, days / 90)
        }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Round numbers feel like anniversaries; 7 years ago does not.
    private func anniversaryWeight(_ years: Int) -> Double {
        switch years {
        case 1:            return 0.95
        case 2, 3:         return 0.8
        case 5, 10, 15, 20: return 1.0
        default:           return 0.55
        }
    }

    private func subtitle(for assets: [AssetRecord], at date: Date) -> String {
        let count = assets.count
        let noun = count == 1 ? "moment" : "moments"
        return "\(count) \(noun) · \(date.formatted(.dateTime.year()))"
    }

    private func eventTitle(for event: EventCluster, assets: [AssetRecord]) -> String {
        if let place = event.placeName { return place }
        let inputs = assets.map {
            ClusterInput(identifier: $0.localIdentifier, date: $0.creationDate,
                         latitude: $0.latitude, longitude: $0.longitude,
                         burstIdentifier: $0.burstIdentifier, isVideo: $0.isVideo,
                         featureVector: nil, memoryScore: $0.memoryScore)
        }
        return EventClustering.title(for: inputs)
    }

    // MARK: Exposure

    private func exposure(for candidateID: String, reference: Date) -> Double {
        let key = "memory:\(candidateID)"
        var descriptor = FetchDescriptor<ExposureRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return 0 }

        if record.dismissed > 0 { return 1 }
        let days = reference.timeIntervalSince(record.lastShownAt) / 86_400
        switch days {
        case ..<1:  return 0.95
        case ..<3:  return 0.6
        case ..<7:  return 0.32
        case ..<21: return 0.12
        default:    return 0
        }
    }

    private func preferenceAdjustment(for candidate: MemoryCandidate,
                                      _ preference: UserPreference,
                                      options: CurationOptions) -> Double {
        var adjustment = preference.kindAffinity[candidate.kind.rawValue] ?? 0
        if candidate.placeName != nil { adjustment += preference.placeAffinity * 0.4 }

        let age = Date.now.timeIntervalSince(candidate.referenceDate) / 86_400
        adjustment += age > 730 ? preference.distantPastAffinity * 0.3
                                : preference.recentPastAffinity * 0.3

        return adjustment + compositionAdjustment(for: candidate, preference, options: options)
    }

    /// What has been learned about the contents of a memory rather than its shape: video,
    /// faces, screenshots.
    ///
    /// Bounded three times over, because a habit should settle a tie between two good memories
    /// and never lift a weak one over a strong one. Each affinity is already clamped to
    /// ±`UserPreference.bound` where it is written; here it is scaled by how much of *this*
    /// memory it actually describes, so a taste for video says nothing about a page of stills;
    /// and the three together are capped, so no single habit can take the feed over. Against a
    /// score that runs 0...1 the whole term is worth a tenth of a point at most.
    private func compositionAdjustment(for candidate: MemoryCandidate,
                                       _ preference: UserPreference,
                                       options: CurationOptions) -> Double {
        // Nothing has been taught yet, so there is nothing to weigh and no reason to pay for
        // the fetch below.
        guard preference.videoAffinity != 0
                || preference.peopleAffinity != 0
                || preference.screenshotAffinity != 0 else { return 0 }

        let assets = records(for: candidate.assetIdentifiers, options: options)
        guard !assets.isEmpty else { return 0 }
        let count = Double(assets.count)

        let videoShare = Double(assets.filter(\.isVideo).count) / count
        let peopleShare = Double(assets.filter { $0.faceCount > 0 }.count) / count
        // Zero unless Include Screenshots is on: curation drops them long before a candidate
        // is built, which is exactly why hiding one has to keep counting for later.
        let screenshotShare = Double(assets.filter(\.isScreenshot).count) / count

        let total = preference.videoAffinity * videoShare * 0.3
            + preference.peopleAffinity * peopleShare * 0.3
            + preference.screenshotAffinity * screenshotShare * 0.3

        return max(-Self.compositionLimit, min(Self.compositionLimit, total))
    }
}

/// Deterministic shuffling so "today's random memory" stays today's, and changes tomorrow.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
