import Foundation
import Observation
import Photos
import SwiftData

/// What one frame's pixel work produced, carried back to the coordinator so the writes stay
/// on the indexer actor, a batch at a time, however many frames were decoded at once.
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
///
/// Nothing heavy runs here. This type is on the main actor, so everything it does is measured
/// against the frames the user is watching: the sweep over the library, the decode and the
/// Vision requests all live in `nonisolated` functions, which under Swift's concurrency rules
/// never run on the caller's actor. What is left on the main actor is bookkeeping.
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

    /// Changes that have arrived but not been folded in yet, and the timer that will do it.
    private var pendingDelta: LibraryDelta?
    private var coalesceTask: Task<Void, Never>?

    /// True once a sweep of the whole library has finished in this process.
    private var hasSweptLibrary = false

    /// The last progress actually published. Everything that reads progress redraws when it
    /// moves, and a batch is far finer than anything that reads it.
    private var lastPublishedProgress: Double = -1

    /// Past this many changes at once, something was imported rather than taken, and a full
    /// pass costs less than repairing the groups around every one of them.
    private static let liveRepairLimit = 64

    /// How long a change is held before it is acted on.
    ///
    /// Photos reports one notification per write, and a library still syncing from iCloud
    /// writes in a long stream of them. Repairing the groups once per notification is the
    /// same repair done over and over for what the user would call one change.
    private static let coalesceWindow = Duration.milliseconds(1200)

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
        // Everything derived is gone, so the library has to be read again from the top.
        hasSweptLibrary = false
        start()
    }

    func clearAnalysisCache() async {
        stop()
        let indexer = LibraryIndexer(modelContainer: container)
        await indexer.clearDerivedData()
        PhotoImageLoader.shared.clearMemoryCache()
        hasSweptLibrary = false
        progress = 0
        lastPublishedProgress = -1
        stage = nil
    }

    private func finish() {
        task = nil
        isRunning = false
        stage = nil
        progress = 1
        lastPublishedProgress = -1
        note(pauseReason: nil)
    }

    // MARK: The pass

    private func run() async {
        let indexer = LibraryIndexer(modelContainer: container)
        await indexer.updateState { $0.lastIndexStartedAt = .now }

        // The whole library is re-read only when nothing in this process has read it yet.
        // After that the change observer is the better source: it stays registered for as
        // long as the app is alive and Photos hands over everything that moved while the app
        // was away, so a second sweep could only find what has already been folded in — and
        // it is fifteen thousand database reads to find it. Coming back to the foreground was
        // paying for one of those every single time.
        //
        // The second clause is the safety valve. If the row count and the library's own count
        // have drifted apart, the observer missed something, and a library quietly missing
        // photographs is a worse outcome than reading it again.
        let indexedTotal = await indexer.totalCount()
        let counted = library.assetCount
        if !hasSweptLibrary || (counted > 0 && counted != indexedTotal) {
            await runMetadata(indexer)
        }
        guard !Task.isCancelled else { return }

        await runPixels(indexer)
        guard !Task.isCancelled else { return }

        // Clustering reads and rewrites the whole table, so it only earns its cost when
        // something has actually moved since the groups were last built.
        if await indexer.needsClusterRebuild() {
            await setStage(.events, progress: 0, through: indexer)
            await indexer.rebuildGroups()
            await indexer.markClustersRebuilt()
        }
        await setStage(.events, progress: 1, through: indexer)

        await runMemories(indexer)

        await indexer.updateState {
            $0.lastIndexFinishedAt = .now
            $0.analysisVersion = currentAnalysisVersion
        }
    }

    /// Stage 1. Fast, and the point at which the app stops being empty.
    private func runMetadata(_ indexer: LibraryIndexer) async {
        await setStage(.metadata, progress: 0, through: indexer)

        let expected = max(1, PhotoLibraryService.currentAssetCount())
        let seen = await Self.sweep(into: indexer, expected: expected, reportingTo: self)
        guard !Task.isCancelled else { return }

        // Pruning by "everything not in this set" is a claim about the whole library, which
        // only a sweep that saw all of it is in a position to make. A sweep cut short, or one
        // that raced an import still in progress, would otherwise delete rows for photographs
        // that are still there.
        if seen.count >= expected, PhotoLibraryService.currentAssetCount() == seen.count {
            _ = await indexer.prune(keeping: seen)
        }

        let total = await indexer.totalCount()
        await indexer.updateState { state in
            state.indexedCount = total
            state.stageProgress[AnalysisStage.metadata.rawValue] = 1
            state.stageProgress[AnalysisStage.thumbnails.rawValue] = 1
        }
        indexedCount = total
        hasUsableIndex = total > 0
        hasSweptLibrary = true
        await setStage(.thumbnails, progress: 1, through: indexer)
    }

    /// Read every asset in the library into the index, off the main actor.
    ///
    /// `nonisolated` is load-bearing: a non-isolated async function never runs on the caller's
    /// actor, so this walk — fifteen thousand faults out of the Photos database — happens
    /// nowhere near the frames being drawn. It used to be the first few seconds of every
    /// launch, spent with the screen not responding.
    private nonisolated static func sweep(into indexer: LibraryIndexer,
                                          expected: Int,
                                          reportingTo coordinator: AnalysisCoordinator) async -> Set<String> {
        var seen = Set<String>()
        seen.reserveCapacity(expected)
        var processed = 0

        await PhotoLibraryService.enumerateSnapshots(chunkSize: 400) { chunk in
            for snapshot in chunk { seen.insert(snapshot.localIdentifier) }
            await indexer.ingest(chunk)
            processed += chunk.count
            await coordinator.noteSweepProgress(min(1, Double(processed) / Double(expected)),
                                                indexed: processed)
        }
        return seen
    }

    private func noteSweepProgress(_ fraction: Double, indexed: Int) {
        progress = fraction
        indexedCount = indexed
        if !hasUsableIndex && indexed > 0 { hasUsableIndex = true }
    }

    /// Stages 3 and 4, batched and rationed by what the device can afford.
    private func runPixels(_ indexer: LibraryIndexer) async {
        await setStage(.similarity, progress: 0, through: indexer)
        lastPublishedProgress = -1

        let initialPending = await indexer.pendingPixelCount()
        guard initialPending > 0 else {
            await setPixelProgress(1, through: indexer)
            return
        }
        var remaining = initialPending
        pendingCount = remaining

        let clock = ContinuousClock()
        var previousHead: String?
        var stalledBatches = 0

        while !Task.isCancelled {
            let allowance = DeviceConditions.current()
            note(pauseReason: DeviceConditions.explanation(for: allowance))

            guard allowance.allowsPixelWork else {
                try? await Task.sleep(for: allowance.minimumPause)
                continue
            }

            let batch = await indexer.pendingPixelWork(limit: allowance.batchSize)
            guard !batch.isEmpty else { break }

            // The queue is ordered, so the asset at the front of it can only still be at the
            // front if the last batch wrote nothing. Once or twice that is a photograph being
            // edited in Photos while the pass runs, which puts it straight back on the queue.
            // Past that it is a loop, and a loop here is the single worst way this app could
            // spend a charge, so the pass gives up and leaves the rest for the next one.
            let head = batch.first?.identifier
            if head == previousHead {
                stalledBatches += 1
                if stalledBatches >= 3 { break }
            } else {
                stalledBatches = 0
            }
            previousHead = head

            let started = clock.now
            await analyze(batch, allowance: allowance, through: indexer)
            let elapsed = clock.now - started

            remaining = max(0, remaining - batch.count)
            pendingCount = remaining
            await setPixelProgress(Double(initialPending - remaining) / Double(initialPending),
                                   through: indexer)

            // Hand the device back for roughly as long as this batch held it. Without this the
            // pass is simply the phone running flat out for as long as the library takes,
            // which is what four percent of a charge in a few minutes actually sounds like.
            try? await Task.sleep(for: allowance.pause(after: elapsed))
        }

        note(pauseReason: nil)
        await setPixelProgress(1, through: indexer)
    }

    /// Analyse a batch and write what it produced, in one transaction.
    ///
    /// Reports how many frames were actually analysed, which is what a live change has to
    /// know: each of those is a new feature print the groups do not yet reflect.
    @discardableResult
    private func analyze(_ batch: [PendingAsset],
                         allowance: WorkAllowance,
                         through indexer: LibraryIndexer) async -> Int {
        guard !batch.isEmpty else { return 0 }
        let results = await Self.analyzeFrames(batch, concurrency: allowance.concurrency)
        return await Self.write(results, through: indexer)
    }

    /// Decode and analyse a batch, a few frames at a time, entirely off the main actor.
    ///
    /// One frame at a time leaves the device mostly waiting: each asset waits on Photos for
    /// its pixels and then on Vision for its answers, and neither wait wants the hardware the
    /// other one is using. A few in flight overlap those waits.
    ///
    /// The ceiling comes from `WorkAllowance`, which sizes it against the machine and against
    /// what the phone can afford at this moment — a hot or unplugged phone runs one frame at a
    /// time. Past a handful the spare capacity is imaginary anyway: every frame in flight is a
    /// decoded image held in memory and half a dozen Vision requests competing for the same
    /// cores and the same Neural Engine.
    private nonisolated static func analyzeFrames(_ batch: [PendingAsset],
                                                  concurrency: Int) async -> [PixelResult] {
        let assets = PhotoLibraryService.assets(for: batch.map(\.identifier))
        let limit = max(1, min(concurrency, batch.count))

        return await withTaskGroup(of: PixelResult.self) { group -> [PixelResult] in
            var results: [PixelResult] = []
            results.reserveCapacity(batch.count)
            var queue = batch[...]

            for pending in queue.prefix(limit) {
                let asset = assets[pending.identifier]
                group.addTask { await Self.pixelWork(for: pending, asset: asset) }
            }
            queue = queue.dropFirst(limit)

            while let result = await group.next() {
                results.append(result)

                // Cancellation stops the queue rather than the work already in flight: those
                // frames have been decoded and analysed, and throwing the answers away would
                // only mean decoding them again next time.
                guard !Task.isCancelled, let pending = queue.popFirst() else { continue }
                let asset = assets[pending.identifier]
                group.addTask { await Self.pixelWork(for: pending, asset: asset) }
            }
            return results
        }
    }

    /// One frame, off the main actor.
    ///
    /// Where the file came from is read here rather than in the metadata pass because
    /// `PHAssetResource.assetResources(for:)` is a lookup per asset, and the metadata pass is
    /// the one the user is waiting on before the app has anything at all to show. Here it sits
    /// alongside a decode and every Vision request the pipeline makes, which cost incomparably
    /// more, and it is only ever done once per asset.
    private nonisolated static func pixelWork(for pending: PendingAsset,
                                              asset: PHAsset?) async -> PixelResult {
        guard let asset else {
            return PixelResult(identifier: pending.identifier, outcome: .unscorable)
        }

        switch await IndexingImageProvider.image(for: asset) {
        case .image(let image):
            // Faces come out of the same requests, from the frame that has already been
            // decoded. Finding people is the one thing here that would be indefensible to
            // decode — or detect — a second time for.
            let (analysis, faces) = await VisionAnalyzer.analyze(image)
            let provenance = pending.needsProvenance ? await ProvenanceReader.read(asset) : nil
            return PixelResult(identifier: pending.identifier,
                               outcome: .analyzed(analysis, faces, provenance))

        case .inCloud:
            return PixelResult(identifier: pending.identifier, outcome: .inCloud)

        case .unavailable:
            return PixelResult(identifier: pending.identifier, outcome: .unscorable)
        }
    }

    @discardableResult
    private nonisolated static func write(_ results: [PixelResult],
                                          through indexer: LibraryIndexer) async -> Int {
        guard !results.isEmpty else { return 0 }

        var frames: [AnalyzedFrame] = []
        var inCloud: [String] = []
        var unscorable: [String] = []
        frames.reserveCapacity(results.count)

        for result in results {
            switch result.outcome {
            case .analyzed(let analysis, let faces, let provenance):
                frames.append(AnalyzedFrame(identifier: result.identifier,
                                            analysis: analysis,
                                            faces: faces,
                                            provenance: provenance))
            case .inCloud:
                inCloud.append(result.identifier)
            case .unscorable:
                unscorable.append(result.identifier)
            }
        }

        await indexer.store(frames, inCloud: inCloud, unscorable: unscorable)
        return frames.count
    }

    /// Feature prints and quality come out of one decode, so both stages advance on the same
    /// number rather than leaving similarity reading zero forever. The status line names
    /// quality, because that is the half still being worked on when a batch reports.
    ///
    /// Published and written to disk a percent at a time, not once per batch. Each write here
    /// redraws every screen watching it and costs a transaction on the bookkeeping row, and
    /// there is no progress bar and no status line anywhere finer than a percent.
    private func setPixelProgress(_ value: Double, through indexer: LibraryIndexer) async {
        if stage != .quality { stage = .quality }
        guard value >= 1 || value - lastPublishedProgress >= 0.01 else { return }

        lastPublishedProgress = value
        progress = value
        await indexer.updateState {
            $0.stageProgress[AnalysisStage.similarity.rawValue] = value
            $0.stageProgress[AnalysisStage.quality.rawValue] = value
            $0.currentStageRaw = AnalysisStage.quality.rawValue
        }
    }

    /// Only publish when it actually changed. Observation invalidates on every write, not
    /// only on every change, and this is written once per batch — so setting it to the same
    /// nil it already held was redrawing the status line hundreds of times over a pass.
    private func note(pauseReason reason: String?) {
        if pauseReason != reason { pauseReason = reason }
    }

    /// Stage 6. The coordinator does not build the feed — `HomeModel` does, on demand, from
    /// what the passes above leave behind. Building it here as well would make the user pay
    /// for a whole second run to fill in a progress bar, so this stage reports the only thing
    /// that is actually true at this point: every input the memory engine reads now exists.
    /// An empty library stops short of 1, which is honest — there is nothing to remember yet.
    private func runMemories(_ indexer: LibraryIndexer) async {
        await setStage(.memories, progress: 0, through: indexer)
        guard await indexer.totalCount() > 0 else { return }
        await setStage(.memories, progress: 1, through: indexer)
    }

    /// The pass's own indexer, rather than one made for the occasion: a progress update is a
    /// write to the same row the pass is counting on, and two contexts holding that row is how
    /// one of them ends up saving what the other had already moved on from.
    private func setStage(_ stage: AnalysisStage,
                          progress: Double,
                          through indexer: LibraryIndexer) async {
        if self.stage != stage { self.stage = stage }
        if self.progress != progress { self.progress = progress }
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
                self.enqueue(delta)
            }
        }
    }

    /// Hold a change back for a moment and fold anything that follows into it.
    ///
    /// A library still syncing from iCloud arrives as a long stream of notifications, and
    /// acting on each one means ingesting, analysing and repairing the groups over and over
    /// for what is really one change. Waiting out the rest of it costs a second.
    private func enqueue(_ delta: LibraryDelta) {
        if var pending = pendingDelta {
            pending.inserted += delta.inserted
            pending.updated += delta.updated
            pending.removedIdentifiers += delta.removedIdentifiers
            pending.libraryCount = delta.libraryCount
            // One unreadable change in the run makes the whole run unreadable: there is no
            // way to describe the rest of it relative to a state nobody can name.
            pending.isIncremental = pending.isIncremental && delta.isIncremental
            pendingDelta = pending
        } else {
            pendingDelta = delta
        }

        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceWindow)
            guard !Task.isCancelled else { return }
            await self?.drainPendingChange()
        }
    }

    private func drainPendingChange() async {
        guard let delta = pendingDelta else { return }
        pendingDelta = nil
        await ingestLive(delta)
    }

    /// Fold one change into the index immediately, touching only what changed.
    private func ingestLive(_ delta: LibraryDelta) async {
        // Photos could not say what moved, which happens when the Limited Access selection is
        // edited. Only a full sweep can find out.
        guard delta.isIncremental else {
            hasSweptLibrary = false
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
            // The rows are already in; what is left is the pixel work and the groups, which
            // is exactly what a pass does. The library itself does not need reading again.
            start()
            return
        }

        // A hot or nearly flat phone gets the row and nothing more; the next pass will find
        // the pixels still owing, exactly as it would for a photo taken while the app was shut.
        let allowance = DeviceConditions.current()
        if allowance.allowsPixelWork {
            let pending = await indexer.pendingPixelWork(among: changed.map(\.localIdentifier))
            handled.updated += await analyze(pending, allowance: allowance, through: indexer)
        }

        // Snapshots carry the library's own date and nothing else — a truer capture date is
        // only recovered later, in the pixel pass. Repairing the cluster window around where
        // Photos filed the change is correct, and the pass that corrects the date repairs
        // that window again.
        let dates = changed.map(\.creationDate) + removal.dates
        await indexer.rebuildClusters(around: dates, accountingFor: handled)
    }
}
