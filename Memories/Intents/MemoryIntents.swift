import AppIntents
import Foundation
import Observation

// MARK: - The times a person would ask for

/// The stretches of time worth offering to Siri and the Shortcuts editor.
///
/// A subset of `TimeWindow`, not a mirror of it. The windows left out — one named day across
/// every year, one named year — only mean anything once a calendar is already in front of
/// you, and a spoken phrase has no calendar in front of it. The full set stays in Explore
/// Time, where it always was.
///
/// Raw values end up stored inside shortcuts people have built, so they are permanent.
enum MemoryTimeWindow: String, CaseIterable, AppEnum {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case thisYear
    case lastYear
    case onThisDay
    case aYearAgo
    case twoYearsAgo
    case threeYearsAgo
    case fiveYearsAgo
    case tenYearsAgo
    case thisWeekLastYear
    case thisWeekThroughTheYears
    case thisMonthThroughTheYears
    case thisSeasonInPastYears
    case thisMonthEveryYear
    case surpriseMe

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Time"

    /// Each of these becomes something said out loud, which is why the anniversaries are
    /// spelled out here and written "3 Years Ago" on screen.
    static var caseDisplayRepresentations: [MemoryTimeWindow: DisplayRepresentation] {
        [
            .today: "Today",
            .yesterday: "Yesterday",
            .thisWeek: "This Week",
            .lastWeek: "Last Week",
            .thisMonth: "This Month",
            .lastMonth: "Last Month",
            .thisYear: "This Year",
            .lastYear: "Last Year",
            .onThisDay: "On This Day",
            .aYearAgo: "A Year Ago",
            .twoYearsAgo: "Two Years Ago",
            .threeYearsAgo: "Three Years Ago",
            .fiveYearsAgo: "Five Years Ago",
            .tenYearsAgo: "Ten Years Ago",
            .thisWeekLastYear: "This Week Last Year",
            .thisWeekThroughTheYears: "This Week Through the Years",
            .thisMonthThroughTheYears: "This Month Through the Years",
            .thisSeasonInPastYears: "This Season in Past Years",
            .thisMonthEveryYear: "This Month Every Year",
            .surpriseMe: "Surprise Me",
        ]
    }

    /// The window this opens.
    ///
    /// Both `TimeWindow` cases that carry a number are pinned here rather than exposed.
    /// Anniversaries get a case each, and "this month every year" resolves against the month
    /// you are actually in — every August in August, every September in September. Asking a
    /// person to say a month number would be the wrong way round.
    var timeWindow: TimeWindow {
        switch self {
        case .today:                    return .today
        case .yesterday:                return .yesterday
        case .thisWeek:                 return .thisWeek
        case .lastWeek:                 return .lastWeek
        case .thisMonth:                return .thisMonth
        case .lastMonth:                return .lastMonth
        case .thisYear:                 return .thisYear
        case .lastYear:                 return .lastYear
        case .onThisDay:                return .onThisDay
        case .aYearAgo:                 return .yearsAgo(1)
        case .twoYearsAgo:              return .yearsAgo(2)
        case .threeYearsAgo:            return .yearsAgo(3)
        case .fiveYearsAgo:             return .yearsAgo(5)
        case .tenYearsAgo:              return .yearsAgo(10)
        case .thisWeekLastYear:         return .thisWeekLastYear
        case .thisWeekThroughTheYears:  return .thisWeekInPreviousYears
        case .thisMonthThroughTheYears: return .thisMonthInPreviousYears
        case .thisSeasonInPastYears:    return .thisSeasonInPreviousYears
        case .thisMonthEveryYear:
            return .everyMonth(Calendar.current.component(.month, from: .now))
        case .surpriseMe:               return .surpriseMe
        }
    }
}

// MARK: - Handing an intent to the app

/// What an intent asked the app to open, held until there is an app to open it in.
///
/// An intent can be performed while the app is launching, before any scene exists, so
/// `perform()` never presents anything itself. It leaves the request here and `RootView`
/// acts on it — on arrival if the app is already running, on appearance if it is not.
@MainActor
@Observable
final class MemoryIntentRouter {
    enum Target: Equatable {
        case window(TimeWindow)
        case topMemory
    }

    /// Carries an identity rather than being compared by value: asking for "three years ago"
    /// twice in a row is two requests, and the second one still has to open something.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let target: Target
    }

    static let shared = MemoryIntentRouter()

    private(set) var request: Request?

    private init() {}

    static func open(_ target: Target) {
        shared.request = Request(target: target)
    }

    /// Read once — whoever takes a request owns it.
    func take() -> Target? {
        defer { request = nil }
        return request?.target
    }

    /// Today's first memory: the one the feed opens on, built the way the feed builds it.
    static func topMemory(app: AppEnvironment) async -> MemoryCandidate? {
        let engine = app.makeEngine()
        let options = app.settings.curationOptions
        return await engine.buildFeed(options: options, limit: 1).first
    }
}

// MARK: - Intents

/// "Show me three years ago."
struct OpenTimeWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a Time"
    static let description = IntentDescription(
        "Opens Memories on a stretch of time — a day, a week, or the same week in earlier years."
    )
    /// The results are a library's worth of photographs. That belongs on the screen, not read
    /// back to you.
    static let openAppWhenRun = true

    @Parameter(title: "Time", requestValueDialog: "Which stretch of time?")
    var window: MemoryTimeWindow

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$window)")
    }

    func perform() async throws -> some IntentResult {
        await MemoryIntentRouter.open(.window(window.timeWindow))
        return .result()
    }
}

/// "Show me today's memory."
struct ShowTopMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Today's Memory"
    static let description = IntentDescription(
        "Opens the memory at the top of today's feed."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MemoryIntentRouter.open(.topMemory)
        // The feed is ranked against the library as it stands at this moment, so the memory
        // is chosen once the app is up rather than named here and fetched twice.
        return .result(dialog: "Opening today's memory.")
    }
}

// MARK: - Siri

/// Phrases that work the moment the app is installed, without anyone opening Shortcuts.
///
/// Every phrase has to contain the app name; the system requires it, and it is also what
/// keeps "show me three years ago" from meaning something else entirely.
struct MemoriesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTimeWindowIntent(),
            phrases: [
                "Show me \(\.$window) in \(.applicationName)",
                // The bare form is here for the one window nobody would say the long way
                // round: "Surprise me in Memories".
                "\(\.$window) in \(.applicationName)",
            ],
            shortTitle: "Show a Time",
            systemImageName: "clock.arrow.circlepath"
        )

        AppShortcut(
            intent: ShowTopMemoryIntent(),
            phrases: [
                "Show me today's memory in \(.applicationName)",
                "Open today's memory in \(.applicationName)",
            ],
            shortTitle: "Today's Memory",
            systemImageName: "rectangle.stack"
        )
    }
}
