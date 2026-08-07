import Foundation
import Photos
import SwiftData

/// Bumped when a stage's meaning changes. Rows below this are recomputed; everything else
/// is left alone, which is what keeps a second launch cheap.
let currentAnalysisVersion = 2

/// All database work for indexing, on its own actor with its own context.
///
/// The rule the whole design follows: the library is diffed, never rebuilt. A second launch
/// looks at what changed — a handful of new photos, a few deletions — and touches only those.
@ModelActor
actor LibraryIndexer {

    // MARK: Stage 1 — metadata

    /// Insert new assets and refresh changed ones. Cheap enough to run over the whole
    /// library on every launch, which is what makes the delta trustworthy.
    func ingest(_ snapshots: [AssetSnapshot]) -> (inserted: Int, updated: Int) {
        var inserted = 0, updated = 0

        for snapshot in snapshots {
            let identifier = snapshot.localIdentifier
            var descriptor = FetchDescriptor<AssetRecord>(
                predicate: #Predicate { $0.localIdentifier == identifier }
            )
            descriptor.fetchLimit = 1
            let existing = try? modelContext.fetch(descriptor).first

            if let record = existing {
                // Edited in Photos: the pixels changed, so anything derived from them is stale.
                if record.modificationDate != snapshot.modificationDate {
                    apply(snapshot, to: record)
                    record.analysisVersion = 0
                    record.featurePrint = nil
                    record.aestheticsScore = nil
                    updated += 1
                } else if record.isFavoriteInPhotos != snapshot.isFavorite {
                    record.isFavoriteInPhotos = snapshot.isFavorite
                    updated += 1
                }
            } else {
                let record = AssetRecord(localIdentifier: identifier, creationDate: snapshot.creationDate)
                apply(snapshot, to: record)
                modelContext.insert(record)
                inserted += 1
            }
        }

        modelContext.saveIfNeeded()
        return (inserted, updated)
    }

    private func apply(_ snapshot: AssetSnapshot, to record: AssetRecord) {
        record.creationDate = snapshot.creationDate
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

    /// Drop rows for assets that are no longer in the library, and anything hanging off them.
    func prune(keeping identifiers: Set<String>) -> Int {
        guard let all = try? modelContext.fetch(FetchDescriptor<AssetRecord>()) else { return 0 }
        var removed = 0
        for record in all where !identifiers.contains(record.localIdentifier) {
            modelContext.delete(record)
            removed += 1
        }
        if removed > 0 { modelContext.saveIfNeeded() }
        return removed
    }

    func totalCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<AssetRecord>())) ?? 0
    }

    // MARK: Stages 3 and 4 — pixels

    /// Identifiers still awaiting Vision, newest first: the recent past is what the feed
    /// most wants, so it should become good before 2014 does.
    func pendingPixelWork(limit: Int) -> [String] {
        let version = currentAnalysisVersion
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.analysisVersion < version && $0.isLocallyAvailable },
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? modelContext.fetch(descriptor).map(\.localIdentifier)) ?? []
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

    func store(_ analysis: FrameAnalysis, for identifier: String) {
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
        modelContext.saveIfNeeded()
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
            sortBy: [SortDescriptor(\.creationDate, order: .forward)]
        )
        if let date {
            descriptor.predicate = #Predicate { $0.creationDate >= date }
        }
        guard let records = try? modelContext.fetch(descriptor) else { return [] }
        return records.map { record in
            ClusterInput(
                identifier: record.localIdentifier,
                date: record.creationDate,
                latitude: record.latitude,
                longitude: record.longitude,
                burstIdentifier: record.burstIdentifier,
                isVideo: record.isVideo,
                featureVector: record.featurePrint.flatMap(FeatureVector.init(data:)),
                memoryScore: record.memoryScore
            )
        }
    }

    /// Rebuild similarity groups and elect a best shot in each.
    func rebuildSimilarityClusters() {
        let inputs = clusterInputs()
        guard !inputs.isEmpty else { return }

        try? modelContext.delete(model: SimilarityCluster.self)
        var assignments: [String: (UUID?, Bool)] = [:]

        var duplicateCounts: [String: Int] = [:]
        var burstPositions: [String: Int] = [:]

        for group in SimilarityClustering.cluster(inputs) {
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

        applySimilarityAssignments(assignments,
                                   duplicateCounts: duplicateCounts,
                                   burstPositions: burstPositions)
        modelContext.saveIfNeeded()
    }

    private func applySimilarityAssignments(_ assignments: [String: (UUID?, Bool)],
                                            duplicateCounts: [String: Int],
                                            burstPositions: [String: Int]) {
        guard let records = try? modelContext.fetch(FetchDescriptor<AssetRecord>()) else { return }
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

    /// Rebuild occasions from the shape of the shooting itself.
    func rebuildEvents() {
        let inputs = clusterInputs()
        guard !inputs.isEmpty else { return }

        try? modelContext.delete(model: EventCluster.self)
        var assignments: [String: UUID] = [:]

        for group in EventClustering.cluster(inputs) {
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

        if let records = try? modelContext.fetch(FetchDescriptor<AssetRecord>()) {
            for record in records {
                record.eventClusterID = assignments[record.localIdentifier]
            }
        }
        modelContext.saveIfNeeded()
    }

    // MARK: Bookkeeping

    func updateState(_ mutate: (AnalysisState) -> Void) {
        mutate(modelContext.analysisState)
        modelContext.saveIfNeeded()
    }

    func readState<T>(_ read: (AnalysisState) -> T) -> T {
        read(modelContext.analysisState)
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
        modelContext.analysisState.stageProgress = [:]
        modelContext.saveIfNeeded()
    }
}
