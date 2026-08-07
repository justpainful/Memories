import Foundation
import Observation
import Photos
import SwiftData

/// What one frame's pixel work produced, carried back to the coordinator so the writes stay
/// on the indexer actor, one at a time, however many frames were decoded at once.
private struct PixelResult: Sendable {
    enum Outcome: Sendable {
        case analyzed(FrameAnalysis, [DetectedFace], AssetProvenance?)
        /// The original lives only in iCloud. Nothing is downloaded to find out more.
        case inCloud
        case unscorable
    }

    var identifier: String
    var outcome: Outcome
}

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
    private var watchTask: Task<Void, Never>?

    /// Past this many changes at once, something was imported rather than taken, and a full
    /// pass costs less than repairing the groups around every one of them.
    private static let liveRepairLimit = 64

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
        guard library.access.canRead else { return }
        startWatching()

        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.run()
            await MainActor.run { self?.finish() }
        }
    }

    /// Stops the pass, not the watching: a photo taken after indexing has finished still has
    /// to appear, and that is the case this app is in almost all of the time.
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

        // Clustering reads and rewrites the whole table, so it only earns its cost when
        // something has actually moved since the groups were last built.
        if await indexer.needsClusterRebuild() {
            await setStage(.events, progress: 0)
            await indexer.rebuildSimilarityClusters()
            await setStage(.events, progress: 0.5)
            await indexer.rebuildEvents()
            // Who somebody is only emerges from seeing every face at once, so this belongs
            // with the other whole-library passes rather than with any one photo.
            await indexer.rebuildPeople()
            await indexer.markClustersRebuilt()
        }
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
            await indexer.ingest(chunk)
            processed += chunk.count

            await MainActor.run {
                self.progress = min(1, Double(processed) / Double(expected))
                self.indexedCount = processed
                self.hasUsableIndex = processed > 0
            }
        }

        // Only safe here: pruning by "everything not in this set" is a claim about the whole
        // library, which is a thing only a whole pass is in a position to make.
        _ = await indexer.prune(keeping: seen)
        let total = await indexer.totalCount()
        await indexer.updateState { state in
            state.indexedCount = total
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
                continue
            }

            let batch = await indexer.pendingPixelWork(limit: allowance.batchSize)
            guard !batch.isEmpty else { break }

            await analyze(batch, allowance: allowance, through: indexer)

            remaining = max(0, remaining - batch.count)
            pendingCount = remaining
            let done = Double(initialPending - remaining) / Double(initialPending)
            await setPixelProgress(done)

            try? await Task.sleep(for: allowance.pauseBetweenBatches)
        }

        pauseReason = nil
        await setPixelProgress(1)
    }

    /// Decode and analyse a batch, a few frames at a time.
    ///
    /// One frame at a time leaves the device mostly waiting: each asset waits on Photos for
    /// its pixels and then on Vision for its answers, and neither wait wants the hardware the
    /// other one is using. A few in flight overlap those waits.
    ///
    /// The ceiling is deliberately low. Every frame in flight is a decoded image held in
    /// memory and four Vision requests competing for the same silicon, so past a handful the
    /// spare capacity is imaginary and only the memory high-water mark keeps climbing. The
    /// pause between batches, and the batch size itself, still belong to `DeviceConditions` —
    /// a hot phone runs two at a time in batches of eight, not four in batches of twenty-four.
    private func analyze(_ batch: [PendingAsset],
                         allowance: WorkAllowance,
                         through indexer: LibraryIndexer) async {
        guard !batch.isEmpty else { return }
        let assets = PhotoLibraryService.assets(for: batch.map(\.identifier))
        let limit = concurrency(for: allowance)

        await withTaskGroup(of: PixelResult.self) { group in
            var queue = batch[...]

            for pending in queue.prefix(limit) {
                let asset = assets[pending.identifier]
                group.addTask { await Self.pixelWork(for: pending, asset: asset) }
            }
            queue = queue.dropFirst(limit)

            while let result = await group.next() {
                await Self.write(result, through: indexer)

                // Cancellation stops the queue rather than the work already in flight: those
                // frames have been decoded and analysed, and throwing the answers away would
                // only mean decoding them again next time.
                guard !Task.isCancelled, let pending = queue.popFirst() else { continue }
                let asset = assets[pending.identifier]
                group.addTask { await Self.pixelWork(for: pending, asset: asset) }
            }
        }
    }

    private func concurrency(for allowance: WorkAllowance) -> Int {
        max(1, min(allowance == .full ? 4 : 2, allowance.batchSize))
    }

    /// One frame, off the main actor.
    ///
    /// Where the file came from is read here rather than in the metadata pass because
    /// `PHAssetResource.assetResources(for:)` is a lookup per asset, and the metadata pass is
    /// the one the user is waiting on before the app has anything at all to show. Here it sits
    /// alongside a decode and four Vision requests, which cost incomparably more, and it is
    /// only ever done once per asset.
    private nonisolated static func pixelWork(for pending: PendingAsset,
                                              asset: PHAsset?) async -> PixelResult {
        guard let asset else {
            return PixelResult(identifier: pending.identifier, outcome: .unscorable)
        }

        switch await IndexingImageProvider.image(for: asset) {
        case .image(let image):
            let analysis = await VisionAnalyzer.analyze(image)
            // Faces come out of the frame that has already been decoded. Finding people is
            // the one thing here that would be indefensible to decode a second time for.
            let faces = await FaceAnalyzer.faces(in: image)
            let provenance = pending.needsProvenance ? await ProvenanceReader.read(asset) : nil
            return PixelResult(identifier: pending.identifier,
                               outcome: .analyzed(analysis, faces, provenance))

        case .inCloud:
            return PixelResult(identifier: pending.identifier, outcome: .inCloud)

        case .unavailable:
            return PixelResult(identifier: pending.identifier, outcome: .unscorable)
        }
    }

    private nonisolated static func write(_ result: PixelResult,
                                          through indexer: LibraryIndexer) async {
        switch result.outcome {
        case .analyzed(let analysis, let faces, let provenance):
            await indexer.store(analysis, provenance: provenance, for: result.identifier)
            await indexer.storeFaces(faces, for: result.identifier)

        case .inCloud:
            // Catalogued, not downloaded. It genuinely cannot be shown offline, so it stays
            // out of memories until it comes back.
            await indexer.markUnavailable(result.identifier)

        case .unscorable:
            // Present but unreadable this time. It keeps its place in the library — treating
            // a failed thumbnail request as "not on this device" used to remove the photo
            // from every memory for good.
            await indexer.markUnscorable(result.identifier)
        }
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

    // MARK: Living with a library that keeps changing

    /// Follow the library while the app is open.
    ///
    /// Waiting for the next full pass to notice a photo the user just took is the difference
    /// between an app that feels alive and one that feels like a cache of a library.
    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            guard let stream = self?.library.changes else { return }
            for await delta in stream {
                guard let self else { return }
                await self.ingestLive(delta)
            }
        }
    }

    /// Fold one change into the index immediately, touching only what changed.
    private func ingestLive(_ delta: LibraryDelta) async {
        // Photos could not say what moved, which happens when the Limited Access selection is
        // edited. Only a full pass can find out.
        guard delta.isIncremental else {
            start()
            return
        }
        guard !delta.isEmpty else { return }

        let indexer = LibraryIndexer(modelContainer: container)
        let changed = delta.inserted + delta.updated

        var handled = await indexer.ingest(changed)
        let removal = await indexer.remove(delta.removedIdentifiers)
        handled.removed = removal.count

        let total = await indexer.totalCount()
        indexedCount = total
        hasUsableIndex = total > 0

        // The rows now exist, which is all the timeline and the grids need. Everything below
        // is the expensive half, and the running pass will do it anyway.
        guard !isRunning else { return }
        guard changed.count <= Self.liveRepairLimit else {
            start()
            return
        }

        let allowance = DeviceConditions.current()
        if allowance.allowsPixelWork {
            let pending = await indexer.pendingPixelWork(among: changed.map(\.localIdentifier))
            await analyze(pending, allowance: allowance, through: indexer)
        }

        let dates = changed.map(\.creationDate) + removal.dates
        await indexer.rebuildClusters(around: dates, accountingFor: handled)
    }
}
