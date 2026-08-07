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

    func loadIfNeeded(app: AppEnvironment) async {
        let today = Calendar.current.startOfDay(for: .now)
        let options = app.settings.curationOptions
        let generation = app.library.changeGeneration

        let isStale = builtForDay != today
            || builtForGeneration != generation
            || builtForOptions != options
        guard isStale, !isBuilding else { return }

        builtForDay = today
        builtForGeneration = generation
        builtForOptions = options
        await build(app: app)
    }

    func reload(app: AppEnvironment) async {
        await build(app: app)
    }

    private func build(app: AppEnvironment) async {
        isBuilding = true
        defer { isBuilding = false }

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
