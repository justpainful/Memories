import Foundation
import Observation
import SwiftData
import SwiftUI

/// Builds and holds today's feed.
///
/// The feed is rebuilt when the day changes, when the library changes, or when curation
/// settings change — not on every appearance, so scrolling away and back does not shuffle
/// the page under the user.
@MainActor
@Observable
final class HomeModel {
    private(set) var candidates: [MemoryCandidate] = []
    private(set) var yearSlices: [String: [YearSlice]] = [:]
    private(set) var isBuilding = false

    private var builtForDay: Date?
    private var builtForGeneration = -1
    private var builtForOptions: CurationOptions?
    /// How much of the library the page was built from. Indexing finishing is a reason to
    /// build again; indexing merely *stopping* is not, and it stops every time the app is
    /// brought forward with nothing left to do.
    private var builtForIndexedCount = -1

    func loadIfNeeded(app: AppEnvironment) async {
        let isStale = builtForDay != Calendar.current.startOfDay(for: .now)
            || builtForGeneration != app.library.changeGeneration
            || builtForOptions != app.settings.curationOptions
            || app.coordinator.indexedCount > builtForIndexedCount
        guard isStale else { return }
        await build(app: app)
    }

    func reload(app: AppEnvironment) async {
        await build(app: app)
    }

    /// Assembles today's page, one build at a time.
    ///
    /// The guard is not defensive tidiness. Two of the things that ask for a rebuild arrive in
    /// the same frame — a pass finishing, and the library generation it bumped — and two builds
    /// running over each other publish their pages in whichever order they happen to finish,
    /// which the reader sees as the feed re-ordering itself under them. Each one also recorded
    /// every memory on it as shown, and that count is what decides whether a memory may appear
    /// again tomorrow.
    private func build(app: AppEnvironment) async {
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }

        // Stamped before the work, not after: what this page was built from is known now, and
        // a change that lands mid-build should leave the page stale rather than be forgotten.
        builtForDay = Calendar.current.startOfDay(for: .now)
        builtForGeneration = app.library.changeGeneration
        builtForOptions = app.settings.curationOptions
        builtForIndexedCount = app.coordinator.indexedCount

        let engine = app.makeEngine()
        let built = await engine.buildFeed(options: app.settings.curationOptions)
        candidates = built
        yearSlices = Self.sliceByYear(built, context: app.container.mainContext)

        // Exposure is recorded when a memory reaches the feed, which is what stops the same
        // page appearing tomorrow.
        let feedback = app.feedback
        for candidate in built { feedback.recordShown(candidate) }
    }

    /// Group a "through the years" memory into one column per year.
    private static func sliceByYear(_ candidates: [MemoryCandidate],
                                    context: ModelContext) -> [String: [YearSlice]] {
        var result: [String: [YearSlice]] = [:]
        let calendar = Calendar.current

        for candidate in candidates where candidate.presentation == .throughTheYears {
            let records = LibraryQuery.records(for: candidate.assetIdentifiers, context: context)
            let grouped = Dictionary(grouping: records) { calendar.component(.year, from: $0.momentDate) }

            result[candidate.id] = grouped
                .map { year, assets in
                    YearSlice(
                        year: year,
                        assetIdentifiers: assets.map(\.localIdentifier),
                        coverIdentifier: Curator.cover(for: assets)?.localIdentifier
                    )
                }
                .sorted { $0.year > $1.year }
        }
        return result
    }
}
