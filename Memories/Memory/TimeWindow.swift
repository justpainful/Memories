import Foundation

/// Every way this app knows how to cut time.
///
/// One vocabulary serves Explore Time, the filter row, Search and the memory generators, so
/// "This week in previous years" means exactly the same thing everywhere it appears.
enum TimeWindow: Hashable, Identifiable, Sendable {
    // Recent
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case thisYear
    case lastYear

    // Historical
    case onThisDay
    case yearsAgo(Int)
    case thisWeekLastYear
    case thisWeekInPreviousYears
    case thisMonthInPreviousYears
    case thisSeasonInPreviousYears
    case sameWeekendInPreviousYears

    /// "Every August" — one calendar month across the whole library.
    case everyMonth(Int)
    /// One specific calendar day across every year — what the Calendar screen opens.
    case dayAcrossYears(month: Int, day: Int)
    case year(Int)
    case surpriseMe

    var id: String { title }

    // MARK: Naming

    var title: String {
        switch self {
        case .today:      return "Today"
        case .yesterday:  return "Yesterday"
        case .thisWeek:   return "This Week"
        case .lastWeek:   return "Last Week"
        case .thisMonth:  return "This Month"
        case .lastMonth:  return "Last Month"
        case .thisYear:   return "This Year"
        case .lastYear:   return "Last Year"
        case .onThisDay:  return "On This Day"
        case .yearsAgo(let n):
            return n == 1 ? "A Year Ago" : "\(n) Years Ago"
        case .thisWeekLastYear:            return "This Week Last Year"
        case .thisWeekInPreviousYears:     return "This Week Through Years"
        case .thisMonthInPreviousYears:    return "This Month Through Years"
        case .thisSeasonInPreviousYears:   return "Same Season"
        case .sameWeekendInPreviousYears:  return "Same Weekend"
        case .everyMonth(let month):
            let symbols = Calendar.current.monthSymbols
            let name = symbols.indices.contains(month - 1) ? symbols[month - 1] : "Month"
            return "Every \(name)"
        case .dayAcrossYears(let month, let day):
            var components = DateComponents()
            components.month = month
            components.day = day
            let date = Calendar.current.date(from: components) ?? .now
            return date.formatted(.dateTime.month(.wide).day())
        case .year(let year):  return String(year)
        case .surpriseMe:      return "Surprise Me"
        }
    }

    /// The Explore Time panel, in the order the user reads it.
    static let exploreGroups: [[TimeWindow]] = [
        [.today, .thisWeek, .thisMonth, .thisYear],
        [.onThisDay, .thisWeekInPreviousYears, .thisMonthInPreviousYears, .thisSeasonInPreviousYears],
        [.yearsAgo(1), .yearsAgo(2), .yearsAgo(3), .yearsAgo(5), .yearsAgo(10)],
        [.surpriseMe],
    ]

    /// The compact filter row above the feed.
    static let quickFilters: [TimeWindow] = [
        .today, .thisWeek, .lastWeek, .onThisDay, .thisMonth, .thisYear, .lastYear, .surpriseMe,
    ]

    // MARK: Resolution

    /// The date spans this window covers. Several spans is normal — "through the years"
    /// windows return one per year — and each is fetched separately so the creationDate
    /// index does the work instead of a full scan plus in-memory filtering.
    func intervals(reference: Date = .now,
                   calendar: Calendar = .current,
                   yearsBack: Int = 20) -> [DateInterval] {
        switch self {
        case .today:
            return [calendar.dayInterval(for: reference)]
        case .yesterday:
            let day = calendar.date(byAdding: .day, value: -1, to: reference) ?? reference
            return [calendar.dayInterval(for: day)]
        case .thisWeek:
            return [calendar.weekInterval(for: reference)]
        case .lastWeek:
            let day = calendar.date(byAdding: .weekOfYear, value: -1, to: reference) ?? reference
            return [calendar.weekInterval(for: day)]
        case .thisMonth:
            return [calendar.monthInterval(for: reference)]
        case .lastMonth:
            let day = calendar.date(byAdding: .month, value: -1, to: reference) ?? reference
            return [calendar.monthInterval(for: day)]
        case .thisYear:
            return [calendar.yearInterval(for: reference)]
        case .lastYear:
            let day = calendar.date(byAdding: .year, value: -1, to: reference) ?? reference
            return [calendar.yearInterval(for: day)]

        case .onThisDay:
            return (1...yearsBack).compactMap { back in
                calendar.date(byAdding: .year, value: -back, to: reference)
                    .map { calendar.dayInterval(for: $0) }
            }

        case .yearsAgo(let years):
            guard let day = calendar.date(byAdding: .year, value: -years, to: reference) else { return [] }
            return [calendar.dayInterval(for: day)]

        case .thisWeekLastYear:
            guard let day = calendar.date(byAdding: .year, value: -1, to: reference) else { return [] }
            return [calendar.weekInterval(for: day)]

        case .thisWeekInPreviousYears:
            return (1...yearsBack).compactMap { back in
                calendar.date(byAdding: .year, value: -back, to: reference)
                    .map { calendar.weekInterval(for: $0) }
            }

        case .thisMonthInPreviousYears:
            return (1...yearsBack).compactMap { back in
                calendar.date(byAdding: .year, value: -back, to: reference)
                    .map { calendar.monthInterval(for: $0) }
            }

        case .thisSeasonInPreviousYears:
            return (1...yearsBack).compactMap { back in
                calendar.date(byAdding: .year, value: -back, to: reference)
                    .flatMap { calendar.seasonInterval(for: $0) }
            }

        case .sameWeekendInPreviousYears:
            return (1...yearsBack).compactMap { back in
                calendar.date(byAdding: .year, value: -back, to: reference)
                    .flatMap { calendar.weekendInterval(nearest: $0) }
            }

        case .everyMonth(let month):
            let thisYear = calendar.component(.year, from: reference)
            return (0...yearsBack).compactMap { back in
                calendar.interval(year: thisYear - back, month: month)
            }

        case .dayAcrossYears(let month, let day):
            let thisYear = calendar.component(.year, from: reference)
            return (0...yearsBack).compactMap { back in
                calendar.interval(year: thisYear - back, month: month, day: day)
            }

        case .year(let year):
            return [calendar.interval(year: year)].compactMap { $0 }

        case .surpriseMe:
            // Deliberately unbounded: the picker decides what is worth surfacing, not the clock.
            return [DateInterval(start: .distantPast, end: reference)]
        }
    }

    /// True when this window groups its results by year rather than showing one flat run.
    var isThroughTheYears: Bool {
        switch self {
        case .onThisDay, .thisWeekInPreviousYears, .thisMonthInPreviousYears,
             .thisSeasonInPreviousYears, .sameWeekendInPreviousYears,
             .everyMonth, .dayAcrossYears:
            return true
        default:
            return false
        }
    }
}

// MARK: - Calendar helpers

extension Calendar {
    func dayInterval(for date: Date) -> DateInterval {
        dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
    }

    func weekInterval(for date: Date) -> DateInterval {
        dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }

    func monthInterval(for date: Date) -> DateInterval {
        dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 30 * 86_400)
    }

    func yearInterval(for date: Date) -> DateInterval {
        dateInterval(of: .year, for: date) ?? DateInterval(start: date, duration: 365 * 86_400)
    }

    /// Meteorological seasons: whole months, which is what people mean by "last summer".
    func seasonInterval(for moment: Date) -> DateInterval? {
        let month = component(.month, from: moment)
        let year = component(.year, from: moment)
        let start: (year: Int, month: Int)
        switch month {
        case 3...5:   start = (year, 3)
        case 6...8:   start = (year, 6)
        case 9...11:  start = (year, 9)
        default:      start = (month == 12 ? year : year - 1, 12)
        }
        guard let from = interval(year: start.year, month: start.month)?.start,
              let to = date(byAdding: .month, value: 3, to: from) else { return nil }
        return DateInterval(start: from, end: to)
    }

    /// The weekend closest to a date — Fri/Sat or Sat/Sun depending on the region.
    func weekendInterval(nearest moment: Date) -> DateInterval? {
        if let containing = dateIntervalOfWeekend(containing: moment) { return containing }
        let weekEarlier = date(byAdding: .day, value: -7, to: moment) ?? moment
        return nextWeekend(startingAfter: weekEarlier)
    }

    func interval(year: Int, month: Int? = nil, day: Int? = nil) -> DateInterval? {
        var components = DateComponents()
        components.year = year
        components.month = month ?? 1
        components.day = day ?? 1
        guard let start = self.date(from: components) else { return nil }

        let unit: Calendar.Component = day != nil ? .day : (month != nil ? .month : .year)
        return dateInterval(of: unit, for: start)
    }
}
