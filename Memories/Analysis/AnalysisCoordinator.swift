import Foundation
import Observation
import Photos
import SwiftData

/// Drives the six passes and reports progress in language a person would use.
///
/// One deliberate departure from the stage list: feature prints and quality are computed in
/// the same pass. Both need the same decoded thumbnail, and decoding a large library twice
/// to keep two stage names separate would be a waste the user pays for in heat and battery.
/// Progress is still reported against both stages.
@MainActor
@Observable
final class AnalysisCoordinator {
    private(set) var stage: AnalysisStage?
    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var indexedCount = 0
    private(set) var pendingCount = 0
    private(set) var pauseReason: String?
    /// True once the timeline has something to draw, which is long before analysis finishes.
    private(set) var hasUsableIndex = false

    private let container: ModelContainer
    private let library: PhotoLibraryService
    private var task: Task<Void, Never>?

    init(container: ModelContainer, library: PhotoLibraryService) {
        self.container = container
        self.library = library
    }

    /// Calm, non-technical status. Never "Scanning 1 of 52,492".
    var statusLine: String {
        if let pauseReason { return pauseReason }
        guard isRunning else {
            return hasUsableIndex ? "Your memories are ready" : "Waiting for photo access"
        }
        return stage?.title ?? "Getting your memories ready"
    }

    func start() {
        guard task == nil, library.access.canRead else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.run()
            await MainActor.run { self?.finish() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Re-run everything from scratch — Settings › Reindex Library.
    func reindex() async {
        stop()
        let indexer = LibraryIndexer(modelContainer: container)
        await indexer.clearDerivedData()
        hasUsableIndex = false
        start()
    }

    func clearAnalysisCache() async {
        stop()
        let indexer = LibraryIndexer(modelContainer: container)
        await indexer.clearDerivedData()
        PhotoImageLoader.shared.clearMemoryCache()
        progress = 0
        stage = nil
    }

    private func finish() {
        task = nil
        isRunning = false
        stage = nil
        progress = 1
    }

    // MARK: The pass

    private func run() async {
        let indexer = LibraryIndexer(modelContainer: container)
        await indexer.updateState { $0.lastIndexStartedAt = .now }

        await runMetadata(indexer)
        guard !Task.isCancelled else { return }

        await runPixels(indexer)
        guard !Task.isCancelled else { return }

        await setStage(.events, progress: 0)
        await indexer.rebuildSimilarityClusters()
        await setStage(.events, progress: 0.5)
        await indexer.rebuildEvents()
        await setStage(.events, progress: 1)

        await runMemories(indexer)

        await indexer.updateState {
            $0.lastIndexFinishedAt = .now
            $0.analysisVersion = currentAnalysisVersion
        }
    }

    /// Stage 1. Fast, and the point at which the app stops being empty.
    private func runMetadata(_ indexer: LibraryIndexer) async {
        await setStage(.metadata, progress: 0)

        let expected = max(1, PhotoLibraryService.currentAssetCount())
        var seen = Set<String>()
        seen.reserveCapacity(expected)
        var processed = 0

        await library.enumerateSnapshots(chunkSize: 400) { chunk in
            guard !Task.isCancelled else { return }
            for snapshot in chunk { seen.insert(snapshot.localIdentifier) }
            let delta = await indexer.ingest(chunk)
            processed += chunk.count

            await MainActor.run {
                self.progress = min(1, Double(processed) / Double(expected))
                self.indexedCount = processed
                self.hasUsableIndex = processed > 0
            }
            _ = delta
        }

        let removed = await indexer.prune(keeping: seen)
        let total = await indexer.totalCount()
        await indexer.updateState { state in
            state.indexedCount = total
            state.lastDeltaRemoved = removed
            state.stageProgress[AnalysisStage.metadata.rawValue] = 1
            state.stageProgress[AnalysisStage.thumbnails.rawValue] = 1
        }
        indexedCount = total
        hasUsableIndex = total > 0
        await setStage(.thumbnails, progress: 1)
    }

    /// Stages 3 and 4, batched and throttled by what the device can afford.
    private func runPixels(_ indexer: LibraryIndexer) async {
        await setStage(.similarity, progress: 0)

        let initialPending = await indexer.pendingPixelCount()
        guard initialPending > 0 else {
            await setPixelProgress(1)
            return
        }
        var remaining = initialPending
        pendingCount = remaining

        while !Task.isCancelled {
            let allowance = DeviceConditions.current()
            pauseReason = DeviceConditions.explanation(for: allowance)

            guard allowance.allowsPixelWork else {
                try? await Task.sleep(for: allowance.pauseBetweenBatches)
                if allowance == .suspended { continue }
                continue
            }

            let batch = await indexer.pendingPixelWork(limit: allowance.batchSize)
            guard !batch.isEmpty else { break }

            let assets = PhotoLibraryService.assets(for: batch)
            for identifier in batch {
                guard !Task.isCancelled else { return }
                guard let asset = assets[identifier] else {
                    await indexer.markUnavailable(identifier)
                    continue
                }
                guard let image = await IndexingImageProvider.image(for: asset) else {
                    // Only in iCloud. Catalogued, not downloaded.
                    await indexer.markUnavailable(identifier)
                    continue
                }
                let analysis = await VisionAnalyzer.analyze(image)
                await indexer.store(analysis, for: identifier)
            }

            remaining = max(0, remaining - batch.count)
            pendingCount = remaining
            let done = Double(initialPending - remaining) / Double(initialPending)
            await setPixelProgress(done)

            try? await Task.sleep(for: allowance.pauseBetweenBatches)
        }

        pauseReason = nil
        await setPixelProgress(1)
    }

    /// Feature prints and quality come out of one decode, so both stages advance on the same
    /// number rather than leaving similarity reading zero forever. The status line names
    /// quality, because that is the half still being worked on when a batch reports.
    private func setPixelProgress(_ value: Double) async {
        stage = .quality
        progress = value
        let indexer = LibraryIndexer(modelContainer: container)
        await indexer.updateState {
            $0.stageProgress[AnalysisStage.similarity.rawValue] = value
            $0.stageProgress[AnalysisStage.quality.rawValue] = value
            $0.currentStageRaw = AnalysisStage.quality.rawValue
        }
    }

    /// Stage 6. The coordinator does not build the feed — `HomeModel` does, on demand, from
    /// what the passes above leave behind. Building it here as well would make the user pay
    /// for a whole second run to fill in a progress bar, so this stage reports the only thing
    /// that is actually true at this point: every input the memory engine reads now exists.
    /// An empty library stops short of 1, which is honest — there is nothing to remember yet.
    private func runMemories(_ indexer: LibraryIndexer) async {
        await setStage(.memories, progress: 0)
        guard await indexer.totalCount() > 0 else { return }
        await setStage(.memories, progress: 1)
    }

    private func setStage(_ stage: AnalysisStage, progress: Double) async {
        self.stage = stage
        self.progress = progress
        let indexer = LibraryIndexer(modelContainer: container)
        await indexer.updateState { $0.stageProgress[stage.rawValue] = progress
                                    $0.currentStageRaw = stage.rawValue }
    }
}
