import Foundation
import Observation
import SwiftUI

/// User-facing preferences, kept deliberately short.
///
/// Everything here is stored in `UserDefaults` on this device. There is no account to sync
/// it to and no server to send it to.
@MainActor
@Observable
final class AppSettings {
    // Memories
    var smartCuration: Bool { didSet { store(smartCuration, "smartCuration") } }
    var includeScreenshots: Bool { didSet { store(includeScreenshots, "includeScreenshots") } }
    var includeScreenRecordings: Bool { didSet { store(includeScreenRecordings, "includeScreenRecordings") } }
    var includeDownloads: Bool { didSet { store(includeDownloads, "includeDownloads") } }
    var memoryFrequency: MemoryFrequency { didSet { store(memoryFrequency.rawValue, "memoryFrequency") } }
    var reminderHour: Int { didSet { store(reminderHour, "reminderHour") } }

    // Playback
    var autoplayVideos: Bool { didSet { store(autoplayVideos, "autoplayVideos") } }
    var playLivePhotos: Bool { didSet { store(playLivePhotos, "playLivePhotos") } }
    var playAudio: Bool { didSet { store(playAudio, "playAudio") } }

    // Appearance
    var appearance: AppearanceChoice { didSet { store(appearance.rawValue, "appearance") } }

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        smartCuration = defaults.object(forKey: "smartCuration") as? Bool ?? true
        includeScreenshots = defaults.object(forKey: "includeScreenshots") as? Bool ?? false
        includeScreenRecordings = defaults.object(forKey: "includeScreenRecordings") as? Bool ?? false
        includeDownloads = defaults.object(forKey: "includeDownloads") as? Bool ?? false
        memoryFrequency = MemoryFrequency(rawValue: defaults.string(forKey: "memoryFrequency") ?? "")
            ?? .daily
        reminderHour = defaults.object(forKey: "reminderHour") as? Int ?? 9
        autoplayVideos = defaults.object(forKey: "autoplayVideos") as? Bool ?? true
        playLivePhotos = defaults.object(forKey: "playLivePhotos") as? Bool ?? true
        playAudio = defaults.object(forKey: "playAudio") as? Bool ?? false
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// The curation rules the feed and browsing surfaces should use right now.
    var curationOptions: CurationOptions {
        CurationOptions(
            mode: smartCuration ? .smart : .pure,
            media: .all,
            includeScreenshots: includeScreenshots,
            includeScreenRecordings: includeScreenRecordings,
            includeDownloads: includeDownloads,
            includeHiddenFromMemories: false
        )
    }

    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// How often the app may put a memory on the Lock Screen. Local notifications only.
enum MemoryFrequency: String, CaseIterable, Sendable {
    case off, daily, weekly

    var title: String {
        switch self {
        case .off:    return "Never"
        case .daily:  return "Daily"
        case .weekly: return "Weekly"
        }
    }
}
