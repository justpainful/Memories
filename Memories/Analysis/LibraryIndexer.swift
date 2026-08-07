import Foundation
import Photos
import SwiftData

/// Bumped when a stage's meaning changes. Rows below this are recomputed; everything else
/// is left alone, which is what keeps a second launch cheap.
let currentAnalysisVersion = 2

/// How much of the library one change actually touched.
///
/// The same three numbers are added to `AnalysisState` when a change is ingested and taken
/// back off once the groups have caught up with it, so between them they answer one question:
/// is there anything the clusters on disk do not know about yet.
struct LibraryChangeCounts: Sendable {
    var inserted = 0
    var updated = 0
    var removed = 0

    var isEmpty: Bool { inserted + updated + removed == 0 }
}

/// One asset the pixel stages still owe work on.
struct PendingAsset: Sendable {
    var identifier: String
    /// True when nothing has ever read where this file came from. `PHAssetResource` lookups
    /// are not free, so the answer is worked out once and then kept.
    var needsProvenance: Bool
}

/// All database work for indexing, on its own actor with its own context.
///
/// The rule the whole design follows: the library is diffed, never rebuilt. A second launch
/// looks at what changed — a handful of new photos, a few deletions — and touches only those.
@ModelActor
actor LibraryIndexer {

    /// A gap this wide is a wall: it is longer than any grouping rule can reach across, so
    /// nothing on one side of it can ever be grouped with anything on the other.
    private static let clusterBarrier = max(EventClustering.gapThreshold, SimilarityClustering.window)
    private static let expansionChunk = 64
    /// Sixteen chunks either side. A stretch of shooting that outruns that is not a stretch,
    /// it is the library, and it is cheaper to admit that than to keep searching.
    private static let expansionBudget = 16

    /// The singleton bookkeeping row, held for as long as this actor lives. It is written
    /// once per ingested chunk and once per analysed frame, and re-fetching a one-row table
    /// to add one to a counter is a query the pixel pass would otherwise pay for every photo
    /// in the library.
    private lazy var state: AnalysisState = modelContext.analysisState

    // MARK: Stage 1 — metadata

    /// Insert new assets and refresh changed ones. Cheap enough to run over the whole
    /// library on every launch, which is what makes the delta trustworthy.
    ///
    /// The rows this chunk might already have are read in a single query and matched in
    /// memory. Asking SwiftData for one identifier at a time is the same work expressed as
    /// one round trip to SQLite per asset, which on a library of 15,000 is 15,000 queries for
    /// a pass whose whole job is to find the twenty things that moved.
    @discardableResult
    func ingest(_ snapshots: [AssetSnapshot]) -> LibraryChangeCounts {
        guard !snapshots.isEmpty else { return LibraryChangeCounts() }

        var counts = LibraryChangeCounts()
        var existing = records(matching: snapshots.map(\.localIdentifier))

        for snapshot in snapshots {
            if let record = existing[snapshot.localIdentifier] {
                // Edited in Photos: the pixels changed, so anything derived from them is stale.
                if record.modificationDate != snapshot.modificationDate {
                    apply(snapshot, to: record)
                    record.analysisVersion = 0
                    record.featurePrint = nil
                    record.aestheticsScore = nil
                    counts.updated += 1
                } else if record.isFavoriteInPhotos != snapshot.isFavorite {
                    record.isFavoriteInPhotos = snapshot.isFavorite
                    counts.updated += 1
                }

                // Rows written before `momentDate` existed still carry its default. Filling
                // it in here costs one comparison per asset on a pass that is already
                // touching every row, and avoids a migration that would have to.
                if record.momentDate == .distantPast { record.refreshMomentDate() }
            } else {
                let record = AssetRecord(localIdentifier: snapshot.localIdentifier,
                                         creationDate: snapshot.creationDate)
                apply(snapshot, to: record)
                modelContext.insert(record)
                // One chunk can name the same asset twice, and the second mention must not
                // insert a duplicate row.
                existing[snapshot.localIdentifier] = record
                counts.inserted += 1
            }
        }

        notePending(counts)
        modelContext.saveIfNeeded()
        return counts
    }

    private func apply(_ snapshot: AssetSnapshot, to record: AssetRecord) {
        record.creationDate = snapshot.creationDate
        record.refreshMomentDate()
        record.modificationDate = snapshot.modificationDate
        record.mediaTypeRaw = snapshot.mediaTypeRaw
        record.mediaSubtypesRaw = snapshot.mediaSubtypesRaw
        record.pixelWidth = snapshot.pixelWidth
        record.pixelHeight = snapshot.pixelHeight
        record.duration = snapshot.duration
        record.isFavoriteInPhotos = snapshot.isFavorite
        record.burstIdentifier = snapshot.burstIdentifier
        record.latitude = snapshot.latitude
        record.longitude = snapshot.longitude
    }

    /// Every row named by these identifiers, in one query, keyed for matching in memory.
    private func records(matching identifiers: [String]) -> [String: AssetRecord] {
        guard !identifiers.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate<AssetRecord> { identifiers.contains($0.localIdentifier) }
        )
        guard let found = try? modelContext.fetch(descriptor) else { return [:] }
        return Dictionary(found.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Drop rows for assets that are no longer in the library, and anything hanging off them.
    ///
    /// This reads the whole table to find what is missing from `identifiers`, so it is only
    /// truthful on a pass that saw the whole library. A live change knows exactly what went
    /// and calls `remove(_:)` instead.
    func prune(keeping identifiers: Set<String>) -> Int {
        guard let all = try? modelContext.fetch(FetchDescriptor<AssetRecord>()) else { return 0 }
        var removed = 0
        for record in all where !identifiers.contains(record.localIdentifier) {
            modelContext.delete(record)
            removed += 1
        }
        if removed > 0 {
            notePending(LibraryChangeCounts(removed: removed))
            modelContext.saveIfNeeded()
        }
        return removed
    }

    /// Drop the specific rows Photos says are gone, and report when they happened so the
    /// groups can be repaired over just those stretches of time.
    func remove(_ identifiers: [String]) -> (count: Int, dates: [Date]) {
        let found = records(matching: identifiers)
        guard !found.isEmpty else { return (0, []) }

        let dates = found.values.map(\.momentDate)
        for record in found.values { modelContext.delete(record) }
        notePending(LibraryChangeCounts(removed: found.count))
        modelContext.saveIfNeeded()
        return (found.count, dates)
    }

    func totalCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<AssetRecord>())) ?? 0
    }

    // MARK: Stages 3 and 4 — pixels

    /// Assets still awaiting Vision, newest first: the recent past is what the feed
    /// most wants, so it should become good before 2014 does.
    func pendingPixelWork(limit: Int) -> [PendingAsset] {
        let version = currentAnalysisVersion
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.analysisVersion < version && $0.isLocallyAvailable },
            sortBy: [SortDescriptor(\.momentDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let records = try? modelContext.fetch(descriptor) else { return [] }
        return records.map(pendingAsset)
    }

    /// The subset of these assets that still owes pixel work. A live change hands over
    /// everything Photos touched, most of which usually needs nothing.
    func pendingPixelWork(among identifiers: [String]) -> [PendingAsset] {
        records(matching: identifiers).values
            .filter { $0.analysisVersion < currentAnalysisVersion && $0.isLocallyAvailable }
            .sorted { $0.momentDate > $1.momentDate }
            .map(pendingAsset)
    }

    private func pendingAsset(_ record: AssetRecord) -> PendingAsset {
        PendingAsset(identifier: record.localIdentifier, needsProvenance: record.sourceRaw == nil)
    }

    func pendingPixelCount() -> Int {
        let version = currentAnalysisVersion
        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.analysisVersion < version && $0.isLocallyAvailable }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    func record(for identifier: String) -> AssetRecord? {
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.localIdentifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func store(_ analysis: FrameAnalysis,
               provenance: AssetProvenance? = nil,
               for identifier: String) {
        guard let record = record(for: identifier) else { return }
        record.featurePrint = analysis.featureVector.isEmpty ? nil : analysis.featureVector.data
        record.aestheticsScore = analysis.aesthetics
        record.faceCount = analysis.faceCount
        record.faceQuality = analysis.bestFaceQuality
        record.sharpness = analysis.sharpness
        record.composition = analysis.composition
        record.subjectProminence = analysis.subjectProminence
        record.averageColor = analysis.averageColor
        record.isUtilityImage = analysis.isUtility
        record.memoryScore = QualityScorer.score(inputs(for: record, analysis: analysis))
        record.analysisVersion = currentAnalysisVersion
        if let provenance { apply(provenance, to: record) }

        // A new feature print changes what the groups would come out as, and a bumped
        // pipeline version is the one way rows become stale without the library moving at
        // all. Counting it here is what stops that case being skipped as "nothing changed".
        notePending(LibraryChangeCounts(updated: 1))
        modelContext.saveIfNeeded()
    }

    /// Where the file came from, as far as its name and its resources will admit.
    ///
    /// A recovered date is only believed when it is *earlier* than the one Photos holds: the
    /// case this exists for is a clip that arrived today from a holiday three years ago, and
    /// a recovered date in the future is noise rather than evidence.
    private func apply(_ provenance: AssetProvenance, to record: AssetRecord) {
        record.originalFilename = provenance.originalFilename
        record.sourceRaw = provenance.platform.rawValue
        if let captured = provenance.capturedDate, captured < record.creationDate {
            record.capturedDate = captured
            // The whole point of recovering the date: everything that files this asset by
            // time reads `momentDate`, so the correction has to reach it or it corrects only
            // the label on the viewer.
            record.refreshMomentDate()
        }
    }

    // MARK: People

    /// Thin passthroughs so the model context never leaves this actor. The face work itself
    /// lives in `FaceAnalyzer`, which knows nothing about storage.
    func storeFaces(_ faces: [DetectedFace], for identifier: String) {
        PeopleIndexing.store(faces, for: identifier, in: modelContext)
    }

    /// A whole-library pass, not a per-asset one: who somebody is only emerges from seeing
    /// every face at once.
    func rebuildPeople() {
        PeopleIndexing.rebuildPeople(in: modelContext)
    }

    /// Mark an asset that Photos would only give us by downloading it. Nothing is downloaded,
    /// so it keeps its metadata and stops being offered pixel work.
    func markUnavailable(_ identifier: String) {
        guard let record = record(for: identifier) else { return }
        record.isLocallyAvailable = false
        record.analysisVersion = currentAnalysisVersion
        modelContext.saveIfNeeded()
    }

    /// The frame could not be read, but the asset is here. It stops being offered pixel work
    /// so the queue drains, and keeps a neutral score so it can still appear in a memory —
    /// unlike an iCloud-only asset, there is nothing stopping it being shown.
    func markUnscorable(_ identifier: String) {
        guard let record = record(for: identifier) else { return }
        record.analysisVersion = currentAnalysisVersion
        if record.memoryScore == 0 { record.memoryScore = 0.45 }
        modelContext.saveIfNeeded()
    }

    private func inputs(for record: AssetRecord, analysis: FrameAnalysis) -> QualityInputs {
        QualityInputs(
            aesthetics: analysis.aesthetics,
            isUtility: analysis.isUtility,
            sharpness: analysis.sharpness,
            composition: analysis.composition,
            subjectProminence: analysis.subjectProminence,
            faceCount: analysis.faceCount,
            bestFaceQuality: analysis.bestFaceQuality,
            averageColor: analysis.averageColor,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            isScreenshot: record.isScreenshot,
            isVideo: record.isVideo,
            isFavorite: record.isFavoriteInPhotos,
            duplicateCount: 1,
            burstPosition: 0
        )
    }

    // MARK: Stage 5 — clustering

    func clusterInputs(since date: Date? = nil) -> [ClusterInput] {
        var descriptor = FetchDescriptor<AssetRecord>(
            sortBy: [SortDescriptor(\.momentDate, order: .forward)]
        )
        if let date {
            descriptor.predicate = #Predicate { $0.momentDate >= date }
        }
        guard let records = try? modelContext.fetch(descriptor) else { return [] }
        return records.map(clusterInput)
    }

    private func clusterInput(_ record: AssetRecord) -> ClusterInput {
        ClusterInput(
            identifier: record.localIdentifier,
            date: record.momentDate,
            latitude: record.latitude,
            longitude: record.longitude,
            burstIdentifier: record.burstIdentifier,
            isVideo: record.isVideo,
            featureVector: record.featurePrint.flatMap(FeatureVector.init(data:)),
            memoryScore: record.memoryScore
        )
    }

    /// Whether anything has happened that the groups on disk do not account for.
    ///
    /// Clustering reads and rewrites every row in the library, so on a launch where nothing
    /// moved it spends that entirely to produce what is already there. The counters written by
    /// `ingest`, `prune` and `remove` are what make it skippable; the version check is what
    /// stops a change to the pipeline being skipped along with it.
    func needsClusterRebuild() -> Bool {
        if state.analysisVersion < currentAnalysisVersion { return true }
        return state.lastDeltaInserted + state.lastDeltaModified + state.lastDeltaRemoved > 0
    }

    /// The groups now describe the library as it was last read.
    func markClustersRebuilt() {
        state.lastDeltaInserted = 0
        state.lastDeltaModified = 0
        state.lastDeltaRemoved = 0
        modelContext.saveIfNeeded()
    }

    private func notePending(_ counts: LibraryChangeCounts) {
        guard !counts.isEmpty else { return }
        state.lastDeltaInserted += counts.inserted
        state.lastDeltaModified += counts.updated
        state.lastDeltaRemoved += counts.removed
    }

    /// The groups have caught up with exactly this much change, and no more. What is left on
    /// the counters belongs to a pass that was interrupted before it could rebuild, and has
    /// to stay there until one finishes.
    private func settle(_ handled: LibraryChangeCounts) {
        state.lastDeltaInserted = max(0, state.lastDeltaInserted - handled.inserted)
        state.lastDeltaModified = max(0, state.lastDeltaModified - handled.updated)
        state.lastDeltaRemoved = max(0, state.lastDeltaRemoved - handled.removed)
        modelContext.saveIfNeeded()
    }

    /// Rebuild similarity groups and elect a best shot in each.
    func rebuildSimilarityClusters() {
        guard needsClusterRebuild() else { return }
        let records = allRecords()
        guard !records.isEmpty else { return }

        try? modelContext.delete(model: SimilarityCluster.self)
        applySimilarity(to: records)
        modelContext.saveIfNeeded()
    }

    /// Rebuild occasions from the shape of the shooting itself.
    func rebuildEvents() {
        guard needsClusterRebuild() else { return }
        let records = allRecords()
        guard !records.isEmpty else { return }

        try? modelContext.delete(model: EventCluster.self)
        applyEvents(to: records)
        modelContext.saveIfNeeded()
    }

    /// Repair the groups around a handful of changes without touching the rest of the library.
    ///
    /// Both rules are local in time. Similarity only ever compares a frame against the ones
    /// immediately before it and stops at a gap wider than its window; an occasion always ends
    /// at a gap wider than `EventClustering.gapThreshold`. So a stretch of shooting fenced on
    /// both sides by a gap wider than either can be regrouped entirely on its own: nothing
    /// outside it could have joined it, and nothing inside it could have reached out.
    ///
    /// When a stretch will not end — an afternoon of continuous shooting can outrun the search
    /// — this falls back to the whole library rather than guessing a boundary, because guessing
    /// one splits a burst in half and elects two best shots out of one press of the shutter.
    func rebuildClusters(around dates: [Date], accountingFor handled: LibraryChangeCounts) {
        guard !dates.isEmpty else { return }

        guard let ranges = affectedRanges(for: dates) else {
            rebuildSimilarityClusters()
            rebuildEvents()
            markClustersRebuilt()
            return
        }

        for range in ranges { rebuildClusters(in: range) }
        modelContext.saveIfNeeded()
        settle(handled)
    }

    private func rebuildClusters(in range: ClosedRange<Date>) {
        let records = records(in: range)
        guard !records.isEmpty else { return }

        deleteClusters(referencedBy: records)
        applySimilarity(to: records)
        applyEvents(to: records)
    }

    /// The changed moments widened into the stretches of shooting they belong to, merged where
    /// they meet. Nil when one of them could not be fenced within the search budget.
    private func affectedRanges(for dates: [Date]) -> [ClosedRange<Date>]? {
        var ranges: [ClosedRange<Date>] = []
        for date in dates.sorted() {
            if let last = ranges.last, last.contains(date) { continue }
            guard let start = boundary(before: date), let end = boundary(after: date) else {
                return nil
            }
            ranges.append(start...end)
        }
        return ranges
    }

    /// Walk back through the library until the gap to the frame before is wider than any
    /// grouping rule can cross. That gap is where this stretch of shooting began.
    private func boundary(before date: Date) -> Date? {
        var edge = date
        for _ in 0..<Self.expansionBudget {
            let cutoff = edge
            var descriptor = FetchDescriptor<AssetRecord>(
                predicate: #Predicate { $0.momentDate < cutoff },
                sortBy: [SortDescriptor(\.momentDate, order: .reverse)]
            )
            descriptor.fetchLimit = Self.expansionChunk

            guard let neighbours = try? modelContext.fetch(descriptor), !neighbours.isEmpty else {
                return edge   // nothing earlier exists; the library itself is the fence
            }
            for neighbour in neighbours {
                if edge.timeIntervalSince(neighbour.momentDate) > Self.clusterBarrier {
                    return edge
                }
                edge = neighbour.momentDate
            }
        }
        return nil
    }

    private func boundary(after date: Date) -> Date? {
        var edge = date
        for _ in 0..<Self.expansionBudget {
            let cutoff = edge
            var descriptor = FetchDescriptor<AssetRecord>(
                predicate: #Predicate { $0.momentDate > cutoff },
                sortBy: [SortDescriptor(\.momentDate, order: .forward)]
            )
            descriptor.fetchLimit = Self.expansionChunk

            guard let neighbours = try? modelContext.fetch(descriptor), !neighbours.isEmpty else {
                return edge
            }
            for neighbour in neighbours {
                if neighbour.momentDate.timeIntervalSince(edge) > Self.clusterBarrier {
                    return edge
                }
                edge = neighbour.momentDate
            }
        }
        return nil
    }

    /// Every row, oldest first. Only the whole-library passes have any business asking.
    private func allRecords() -> [AssetRecord] {
        let descriptor = FetchDescriptor<AssetRecord>(
            sortBy: [SortDescriptor(\.momentDate, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func records(in range: ClosedRange<Date>) -> [AssetRecord] {
        let start = range.lowerBound, end = range.upperBound
        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.momentDate >= start && $0.momentDate <= end },
            sortBy: [SortDescriptor(\.momentDate, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Throw away the groups this stretch belongs to before it is regrouped. None of them can
    /// have a member outside the stretch — that is exactly what makes the fence safe to cut on.
    private func deleteClusters(referencedBy records: [AssetRecord]) {
        let similarity = Array(Set(records.compactMap(\.similarityClusterID)))
        let events = Array(Set(records.compactMap(\.eventClusterID)))

        if !similarity.isEmpty {
            let descriptor = FetchDescriptor<SimilarityCluster>(
                predicate: #Predicate<SimilarityCluster> { similarity.contains($0.id) }
            )
            for cluster in (try? modelContext.fetch(descriptor)) ?? [] {
                modelContext.delete(cluster)
            }
        }
        if !events.isEmpty {
            let descriptor = FetchDescriptor<EventCluster>(
                predicate: #Predicate<EventCluster> { events.contains($0.id) }
            )
            for event in (try? modelContext.fetch(descriptor)) ?? [] {
                modelContext.delete(event)
            }
        }
    }

    /// Group these records, elect a best shot in each group, and rescore them now that
    /// duplicate pressure and burst position are known.
    private func applySimilarity(to records: [AssetRecord]) {
        var assignments: [String: (UUID?, Bool)] = [:]
        var duplicateCounts: [String: Int] = [:]
        var burstPositions: [String: Int] = [:]

        for group in SimilarityClustering.cluster(records.map(clusterInput)) {
            guard group.count > 1 else {
                if let only = group.first { assignments[only.identifier] = (nil, true) }
                continue
            }
            // Position within the run matters: the later frames of a burst are usually the
            // ones that were meant to be thrown away.
            for (position, member) in group.sorted(by: { $0.date < $1.date }).enumerated() {
                duplicateCounts[member.identifier] = group.count
                burstPositions[member.identifier] = position
            }
            let best = SimilarityClustering.bestShot(in: group)
            let cluster = SimilarityCluster(
                representativeIdentifier: best?.identifier ?? group[0].identifier,
                memberIdentifiers: group.map(\.identifier)
            )
            cluster.averageSimilarity = SimilarityClustering.averageSimilarity(in: group)
            cluster.analysisVersion = currentAnalysisVersion
            modelContext.insert(cluster)

            for member in group {
                assignments[member.identifier] = (cluster.id, member.identifier == best?.identifier)
            }
        }

        for record in records {
            let (cluster, isBest) = assignments[record.localIdentifier] ?? (nil, true)
            record.similarityClusterID = cluster
            record.isBestInSimilarityCluster = isBest

            // Duplicate pressure and burst position are only knowable once the groups exist,
            // so the score is recomputed here from the stored measurements rather than being
            // nudged by a flat penalty that ignores how big the run actually was.
            record.memoryScore = QualityScorer.score(storedInputs(
                for: record,
                duplicateCount: duplicateCounts[record.localIdentifier] ?? 1,
                burstPosition: burstPositions[record.localIdentifier] ?? 0
            ))
        }
    }

    private func applyEvents(to records: [AssetRecord]) {
        var assignments: [String: UUID] = [:]

        for group in EventClustering.cluster(records.map(clusterInput)) {
            guard let start = group.first?.date, let end = group.last?.date else { continue }
            let event = EventCluster(startDate: start, endDate: end,
                                     assetIdentifiers: group.map(\.identifier))
            event.photoCount = group.filter { !$0.isVideo }.count
            event.videoCount = group.filter(\.isVideo).count
            event.coverIdentifier = group.max { $0.memoryScore < $1.memoryScore }?.identifier
            event.significance = EventClustering.significance(of: group)
            event.latitude = group.compactMap(\.latitude).first
            event.longitude = group.compactMap(\.longitude).first
            event.analysisVersion = currentAnalysisVersion
            modelContext.insert(event)

            for member in group { assignments[member.identifier] = event.id }
        }

        for record in records {
            record.eventClusterID = assignments[record.localIdentifier]
        }
    }

    /// Rebuild the scorer's inputs from what was persisted during the pixel pass.
    private func storedInputs(for record: AssetRecord,
                              duplicateCount: Int,
                              burstPosition: Int) -> QualityInputs {
        QualityInputs(
            aesthetics: record.aestheticsScore,
            isUtility: record.isUtilityImage,
            sharpness: record.sharpness,
            composition: record.composition,
            subjectProminence: record.subjectProminence,
            faceCount: record.faceCount,
            bestFaceQuality: record.faceQuality,
            averageColor: record.averageColor,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            isScreenshot: record.isScreenshot,
            isVideo: record.isVideo,
            isFavorite: record.isFavoriteInPhotos,
            duplicateCount: duplicateCount,
            burstPosition: burstPosition
        )
    }

    // MARK: Bookkeeping

    func updateState(_ mutate: (AnalysisState) -> Void) {
        mutate(state)
        modelContext.saveIfNeeded()
    }

    func readState<T>(_ read: (AnalysisState) -> T) -> T {
        read(state)
    }

    /// "Clear Analysis Cache" — throw away everything derived, keep the user's own choices.
    func clearDerivedData() {
        try? modelContext.delete(model: SimilarityCluster.self)
        try? modelContext.delete(model: EventCluster.self)
        try? modelContext.delete(model: MemoryRecord.self)

        if let records = try? modelContext.fetch(FetchDescriptor<AssetRecord>()) {
            for record in records {
                record.featurePrint = nil
                record.aestheticsScore = nil
                record.faceQuality = nil
                record.sharpness = nil
                record.composition = nil
                record.subjectProminence = nil
                record.memoryScore = 0
                record.analysisVersion = 0
                record.similarityClusterID = nil
                record.isBestInSimilarityCluster = true
                record.eventClusterID = nil
            }
        }
        state.stageProgress = [:]
        // There are no groups left to be in step with, so the next pass must rebuild them
        // whatever the change counters happen to say.
        state.analysisVersion = 0
        modelContext.saveIfNeeded()
    }
}
