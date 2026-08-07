import Foundation
import Testing
@testable import Memories

/// `TimeWindow` is the app's entire vocabulary of time, and every screen that shows anything
/// asks it what a phrase means. A wrong interval never crashes — it quietly returns an empty
/// screen, which is precisely the failure a person will not notice and a test will.
///
/// Every test pins both the reference moment and the calendar, so nothing here can drift with
/// the machine's clock, time zone or region.
struct TimeWindowTests {

    private let calendar = Fixture.calendar()
    /// Saturday, 15 June 2024, midday UTC.
    private let reference = Fixture.date(2024, 6, 15, 12)

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    private func years(_ intervals: [DateInterval]) -> [Int?] {
        intervals.map({ parts($0.start).year })
    }

    // MARK: Recent

    @Test("Today is one day, and it holds the moment we asked about")
    func today() throws {
        let intervals = TimeWindow.today.intervals(reference: reference, calendar: calendar)
        #expect(intervals.count == 1)

        let day = try #require(intervals.first)
        #expect(day.duration == 86_400)
        #expect(day.contains(reference))
        #expect(parts(day.start).year == 2024)
        #expect(parts(day.start).month == 6)
        #expect(parts(day.start).day == 15)
    }

    @Test("Yesterday is the day immediately before today, with no gap and no overlap")
    func yesterdayAdjoinsToday() throws {
        let today = try #require(TimeWindow.today.intervals(reference: reference, calendar: calendar).first)
        let yesterday = try #require(TimeWindow.yesterday.intervals(reference: reference, calendar: calendar).first)

        #expect(yesterday.duration == 86_400)
        #expect(yesterday.end == today.start)
        #expect(parts(yesterday.start).day == 14)
        #expect(yesterday.contains(reference) == false)
    }

    @Test("This week starts on the calendar's own first weekday, not a hardcoded one")
    func thisWeekFollowsFirstWeekday() throws {
        let sundayFirst = Fixture.calendar(firstWeekday: 1)
        let mondayFirst = Fixture.calendar(firstWeekday: 2)

        let sundayWeek = try #require(TimeWindow.thisWeek.intervals(reference: reference, calendar: sundayFirst).first)
        let mondayWeek = try #require(TimeWindow.thisWeek.intervals(reference: reference, calendar: mondayFirst).first)

        #expect(sundayFirst.component(.weekday, from: sundayWeek.start) == 1)
        #expect(mondayFirst.component(.weekday, from: mondayWeek.start) == 2)
        // The reference is a Saturday, so the two regions genuinely disagree about which week
        // it belongs to. If they agreed, this test would be proving nothing.
        #expect(sundayWeek.start != mondayWeek.start)

        #expect(sundayWeek.contains(reference))
        #expect(mondayWeek.contains(reference))
        #expect(sundayWeek.duration == 7 * 86_400)
        #expect(mondayWeek.duration == 7 * 86_400)
    }

    // MARK: Through the years

    @Test("On This Day is one day per year back, each landing on the same date")
    func onThisDay() {
        let intervals = TimeWindow.onThisDay.intervals(reference: reference, calendar: calendar, yearsBack: 5)

        #expect(intervals.count == 5)
        #expect(years(intervals) == [2023, 2022, 2021, 2020, 2019])
        #expect(intervals.allSatisfy({ parts($0.start).month == 6 }))
        #expect(intervals.allSatisfy({ parts($0.start).day == 15 }))
        #expect(intervals.allSatisfy({ $0.duration == 86_400 }))
        // Today is deliberately absent: it is "on this day", not "today".
        #expect(intervals.contains(where: { $0.contains(reference) }) == false)
    }

    @Test("This month in previous years lands on the same month every time")
    func thisMonthInPreviousYears() {
        let intervals = TimeWindow.thisMonthInPreviousYears
            .intervals(reference: reference, calendar: calendar, yearsBack: 3)

        #expect(intervals.count == 3)
        #expect(years(intervals) == [2023, 2022, 2021])
        #expect(intervals.allSatisfy({ parts($0.start).month == 6 }))
        #expect(intervals.allSatisfy({ parts($0.start).day == 1 }))
        #expect(intervals.allSatisfy({ $0.duration == 30 * 86_400 }))   // June
    }

    @Test("Every August is August, in this year and in every year behind it")
    func everyMonth() {
        let intervals = TimeWindow.everyMonth(8).intervals(reference: reference, calendar: calendar, yearsBack: 3)

        // Unlike the "previous years" windows, this one counts from the current year.
        #expect(intervals.count == 4)
        #expect(years(intervals) == [2024, 2023, 2022, 2021])
        #expect(intervals.allSatisfy({ parts($0.start).month == 8 }))
        #expect(intervals.allSatisfy({ parts($0.start).day == 1 }))
        #expect(intervals.allSatisfy({ $0.duration == 31 * 86_400 }))
    }

    @Test("A day across years hits that date in every year")
    func dayAcrossYears() {
        let intervals = TimeWindow.dayAcrossYears(month: 12, day: 25)
            .intervals(reference: reference, calendar: calendar, yearsBack: 2)

        #expect(intervals.count == 3)
        #expect(years(intervals) == [2024, 2023, 2022])
        #expect(intervals.allSatisfy({ parts($0.start).month == 12 }))
        #expect(intervals.allSatisfy({ parts($0.start).day == 25 }))
        #expect(intervals.allSatisfy({ $0.duration == 86_400 }))
    }

    @Test("Years ago is exactly that many years back, to the day")
    func yearsAgo() throws {
        let three = try #require(TimeWindow.yearsAgo(3).intervals(reference: reference, calendar: calendar).first)
        #expect(parts(three.start).year == 2021)
        #expect(parts(three.start).month == 6)
        #expect(parts(three.start).day == 15)
        #expect(three.duration == 86_400)

        let one = try #require(TimeWindow.yearsAgo(1).intervals(reference: reference, calendar: calendar).first)
        #expect(parts(one.start).year == 2023)
        #expect(parts(one.start).day == 15)
    }

    @Test("A leap day steps back onto a real day rather than vanishing")
    func leapDay() throws {
        let leapDay = Fixture.date(2024, 2, 29, 12)

        let ago = try #require(TimeWindow.yearsAgo(1).intervals(reference: leapDay, calendar: calendar).first)
        #expect(parts(ago.start).year == 2023)
        #expect(parts(ago.start).month == 2)
        // 2023 has no 29th, so the calendar clamps to the last day of February. What matters is
        // that a real day comes back: an empty result would blank the screen on one day in four
        // years, which is exactly the sort of bug nobody is around to see.
        #expect(parts(ago.start).day == 28)
        #expect(ago.duration == 86_400)

        let throughYears = TimeWindow.onThisDay.intervals(reference: leapDay, calendar: calendar, yearsBack: 1)
        #expect(throughYears.count == 1)
        #expect(parts(throughYears[0].start).month == 2)
    }

    @Test("A calendar day that does not exist every year still means that day")
    func leapDayAcrossYears() throws {
        let intervals = TimeWindow.dayAcrossYears(month: 2, day: 29)
            .intervals(reference: Fixture.date(2024, 2, 29, 12), calendar: calendar, yearsBack: 2)

        // The leap year itself is never in doubt.
        let leapYear = try #require(intervals.first)
        #expect(parts(leapYear.start).year == 2024)
        #expect(parts(leapYear.start).month == 2)
        #expect(parts(leapYear.start).day == 29)

        // 2023 and 2022 have no 29th. `Calendar.interval(year:month:day:)` builds the date from
        // raw components, and `date(from:)` does not validate — it rolls the overflow forward.
        // So the Calendar screen, opened on a 29 February, heads a list with that date and then
        // fills it with photographs taken on 1 March. Recorded rather than fixed: the fix
        // belongs in the source, which this target does not touch.
        withKnownIssue("29 February in a non-leap year does not resolve to a day in February") {
            #expect(intervals.count == 3)
            #expect(intervals.allSatisfy({ parts($0.start).month == 2 }))
        }
    }

    // MARK: Nothing resolves to nothing

    @Test("Every window in the filter row resolves to at least one real span")
    func quickFiltersAllResolve() {
        for window in TimeWindow.quickFilters {
            let intervals = window.intervals(reference: reference, calendar: calendar, yearsBack: 5)
            #expect(intervals.isEmpty == false, "\(window.title) resolved to nothing")
            #expect(intervals.allSatisfy({ $0.duration > 0 }), "\(window.title) produced a zero-length span")
        }
    }
}
