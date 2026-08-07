import Foundation
import SwiftData

/// One month of the library, summarised.
struct MonthBucket: Sendable, Identifiable, Hashable {
    var year: Int
    var month: Int
    var count: Int
    var coverIdentifier: String?

    var id: Int { year * 100 + month }

    /// The first instant of the month, and the only thing a view should draw a month from.
    ///
    /// Everything a screen wants to say about a month — "August", "August 2019", the order the
    /// two go in, the digits the year is written with — is a formatting question with a
    /// different answer in every language, and a date is the only input that lets the system
    /// answer it. Pasting a month name and a rendered integer together, which is what this
    /// screen used to do, fixes an English word order into the layout.
    var startDate: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    /// The month's name on its own, for a row that already sits under its year.
    ///
    /// Derived from the date rather than indexed out of `monthSymbols`, so it cannot fall
    /// through to a placeholder, and so it follows the reader's calendar rather than assuming
    /// twelve Gregorian months.
    var title: String {
        startDate.formatted(.dateTime.month(.wide))
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

    /// The day itself, so a screen can name it — "Friday 12 August" — instead of announcing a
    /// bare number in a grid whose columns a screen reader cannot see.
    ///
    /// Built through `Calendar.interval(year:month:day:)` rather than `date(from:)` because that
    /// helper already refuses a day the calendar does not have: `date(from:)` rolls 29 February
    /// in a common year forward to 1 March and hands it back without a word, which would label
    /// a cell with the wrong day rather than with none.
    var date: Date? {
        Calendar.current.interval(year: year, month: month, day: day)?.start
    }
}

extension LibraryIndexer {

    /// Month-by-month summary of the whole library.
    ///
    /// Computed here, on the background actor, rather than by grouping every row on the main
    /// thread each time Timeline appears — at 100k assets that is the difference between an
    /// instant screen and a stall.
    func monthBuckets(options: CurationOptions) -> [MonthBucket] {
        let descriptor = FetchDescriptor<AssetRecord>(
            sortBy: [SortDescriptor(\.momentDate, order: .reverse)]
        )
        guard let records = try? modelContext.fetch(descriptor) else { return [] }

        let calendar = Calendar.current
        var counts: [Int: Int] = [:]
        var best: [Int: (String, Double)] = [:]
        var order: [Int] = []

        for record in records where LibraryQuery.passes(record, options: options) {
            let components = calendar.dateComponents([.year, .month], from: record.momentDate)
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
            predicate: #Predicate { $0.momentDate >= start && $0.momentDate < end },
            sortBy: [SortDescriptor(\.momentDate, order: .forward)]
        )
        guard let records = try? modelContext.fetch(descriptor) else { return [] }

        var counts: [Int: Int] = [:]
        var best: [Int: (String, Double)] = [:]

        for record in records where LibraryQuery.passes(record, options: options) {
            let day = calendar.component(.day, from: record.momentDate)
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
