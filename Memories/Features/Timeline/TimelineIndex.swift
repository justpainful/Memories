import Foundation
import SwiftData

/// One month of the library, summarised.
struct MonthBucket: Sendable, Identifiable, Hashable {
    var year: Int
    var month: Int
    var count: Int
    var coverIdentifier: String?

    var id: Int { year * 100 + month }

    var title: String {
        let symbols = Calendar.current.monthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : "Month"
    }

    var startDate: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }
}

/// One day, for the calendar grid.
struct DayBucket: Sendable, Identifiable, Hashable {
    var year: Int
    var month: Int
    var day: Int
    var count: Int
    var coverIdentifier: String?

    var id: Int { year * 10_000 + month * 100 + day }
}

extension LibraryIndexer {

    /// Month-by-month summary of the whole library.
    ///
    /// Computed here, on the background actor, rather than by grouping every row on the main
    /// thread each time Timeline appears — at 100k assets that is the difference between an
    /// instant screen and a stall.
    func monthBuckets(options: CurationOptions) -> [MonthBucket] {
        let descriptor = FetchDescriptor<AssetRecord>(
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        guard let records = try? modelContext.fetch(descriptor) else { return [] }

        let calendar = Calendar.current
        var counts: [Int: Int] = [:]
        var best: [Int: (String, Double)] = [:]
        var order: [Int] = []

        for record in records where LibraryQuery.passes(record, options: options) {
            let components = calendar.dateComponents([.year, .month], from: record.creationDate)
            guard let year = components.year, let month = components.month else { continue }
            let key = year * 100 + month

            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1

            if record.memoryScore > (best[key]?.1 ?? -1) {
                best[key] = (record.localIdentifier, record.memoryScore)
            }
        }

        return order.map { key in
            MonthBucket(year: key / 100,
                        month: key % 100,
                        count: counts[key] ?? 0,
                        coverIdentifier: best[key]?.0)
        }
    }

    /// Per-day summary for one month, for the calendar.
    func dayBuckets(year: Int, month: Int, options: CurationOptions) -> [DayBucket] {
        let calendar = Calendar.current
        guard let interval = calendar.interval(year: year, month: month) else { return [] }
        let start = interval.start
        let end = interval.end

        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.creationDate >= start && $0.creationDate < end },
            sortBy: [SortDescriptor(\.creationDate, order: .forward)]
        )
        guard let records = try? modelContext.fetch(descriptor) else { return [] }

        var counts: [Int: Int] = [:]
        var best: [Int: (String, Double)] = [:]

        for record in records where LibraryQuery.passes(record, options: options) {
            let day = calendar.component(.day, from: record.creationDate)
            counts[day, default: 0] += 1
            if record.memoryScore > (best[day]?.1 ?? -1) {
                best[day] = (record.localIdentifier, record.memoryScore)
            }
        }

        return counts.keys.sorted().map { day in
            DayBucket(year: year, month: month, day: day,
                      count: counts[day] ?? 0, coverIdentifier: best[day]?.0)
        }
    }

    /// Which years have anything at all, newest first — the Timeline scrubber's stops.
    func availableYears(options: CurationOptions) -> [Int] {
        Array(Set(monthBuckets(options: options).map(\.year))).sorted(by: >)
    }
}
