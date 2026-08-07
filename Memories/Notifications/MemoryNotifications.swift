import Foundation
import SwiftData
import UserNotifications

/// Lock Screen memories, with no push infrastructure behind them.
///
/// There is no APNs certificate, no server and no account here, so nothing can be delivered
/// from outside. Instead the app looks at its own database, works out what it *would* show
/// on each of the next few days, and schedules those as local notifications with the text
/// already written. Every launch rewrites the schedule, so the content stays honest as the
/// library changes.
enum MemoryNotifications {
    private static let identifierPrefix = "memory.reminder."
    /// Far enough ahead to survive a week of not opening the app, short enough that the
    /// contents do not go stale.
    private static let daysAhead = 7

    // MARK: Permission

    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    static func authorizationDescription() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized:   return "Allowed"
        case .provisional:  return "Quiet delivery"
        case .ephemeral:    return "Temporary"
        case .denied:       return "Not allowed"
        default:            return "Not requested"
        }
    }

    // MARK: Scheduling

    @MainActor
    static func reschedule(app: AppEnvironment) async {
        let center = UNUserNotificationCenter.current()
        clearPending(center)

        let frequency = app.settings.memoryFrequency
        guard frequency != .off else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let hour = app.settings.reminderHour
        let calendar = Calendar.current
        let engine = app.makeEngine()
        let options = app.settings.curationOptions
        let step = frequency == .daily ? 1 : 7

        for offset in stride(from: step, through: daysAhead, by: step) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: .now) else { continue }

            // Build that day's feed now so the notification can say what it is actually about
            // rather than "You have a new memory".
            let candidates = await engine.buildFeed(reference: day, options: options, limit: 1)
            guard let candidate = candidates.first else { continue }

            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = hour
            components.minute = 0

            let content = UNMutableNotificationContent()
            content.title = candidate.title
            content.body = candidate.subtitle ?? "A memory from your library."
            content.sound = .default
            content.threadIdentifier = "memories"

            let request = UNNotificationRequest(
                identifier: identifierPrefix + "\(offset)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    static func cancelAll() {
        clearPending(UNUserNotificationCenter.current())
    }

    private static func clearPending(_ center: UNUserNotificationCenter) {
        center.getPendingNotificationRequests { requests in
            let ours = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }
}
