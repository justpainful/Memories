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
    var videoMix: VideoMix { didSet { store(videoMix.rawValue, "videoMix") } }

    // Playback
    var autoplayVideos: Bool { didSet { store(autoplayVideos, "autoplayVideos") } }
    var playLivePhotos: Bool { didSet { store(playLivePhotos, "playLivePhotos") } }
    var playAudio: Bool { didSet { store(playAudio, "playAudio") } }

    // Appearance
    var appearance: AppearanceChoice { didSet { store(appearance.rawValue, "appearance") } }

    /// The one preference this object does not store itself. `Typo` has to read the choice
    /// from static context, where no `AppSettings` instance is in reach, so it lives in
    /// `TypographyPreference` and this is a window onto it — read and written here exactly
    /// like the rest.
    var typography: TypographyStyle {
        get { TypographyPreference.shared.style }
        set { TypographyPreference.shared.style = newValue }
    }

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        smartCuration = defaults.object(forKey: "smartCuration") as? Bool ?? true
        includeScreenshots = defaults.object(forKey: "includeScreenshots") as? Bool ?? false
        includeScreenRecordings = defaults.object(forKey: "includeScreenRecordings") as? Bool ?? false
        includeDownloads = defaults.object(forKey: "includeDownloads") as? Bool ?? false
        // Off by default. Turning it on is what asks for notification permission; prompting
        // on first launch, before the user has seen a single memory, earns a "Don't Allow".
        memoryFrequency = MemoryFrequency(rawValue: defaults.string(forKey: "memoryFrequency") ?? "")
            ?? .off
        reminderHour = defaults.object(forKey: "reminderHour") as? Int ?? 9
        videoMix = VideoMix(rawValue: defaults.string(forKey: "videoMix") ?? "") ?? .balanced
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
            includeHiddenFromMemories: false,
            videoMix: videoMix
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

/// How much of a memory may be video.
///
/// Most libraries hold far more photographs than clips, so left to quality scoring alone a
/// memory is almost always stills — and the app was deciding that silently, with no way to say
/// otherwise. This is the say. It is a ceiling rather than a quota: a day with no video still
/// produces a memory of photographs, and asking for more video never invents any.
enum VideoMix: String, CaseIterable, Sendable {
    case rarely, balanced, often

    var title: String {
        switch self {
        case .rarely:   return "Rarely"
        case .balanced: return "Balanced"
        case .often:    return "Often"
        }
    }

    /// The largest share of one memory that may be video.
    var ceiling: Double {
        switch self {
        case .rarely:   return 0.05
        case .balanced: return 0.35
        case .often:    return 0.75
        }
    }

    /// Whether a memory that lost all its clips to quality scoring gets its best one back.
    /// A clip carries a moment stills cannot, so this is on unless the user asked otherwise.
    var reinstatesOne: Bool { self != .rarely }
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

/// Which typeface carries the editorial layer — memory titles, section headlines, the date
/// that opens the feed. Controls, counts and metadata are SF Pro under either choice.
enum TypographyStyle: String, CaseIterable, Sendable {
    case system, editorial

    var title: String {
        switch self {
        case .system:    return "System"
        case .editorial: return "Editorial"
        }
    }

    var design: Font.Design {
        switch self {
        case .system:    return .default
        case .editorial: return .serif
        }
    }
}

/// The typography choice, held once for the whole app.
///
/// It is deliberately not stored on `AppSettings`: `Typo` is a plain enum of statics read
/// from dozens of view bodies that never see an `AppSettings`, and there can be more than one
/// `AppSettings` alive (previews get their own `AppEnvironment`), so a per-instance property
/// would leave some readers observing an object nobody is writing to.
///
/// Not `@MainActor` either. Isolating it would isolate every `Typo` constant that reads it,
/// and those are read from `View` extensions and other places that carry no isolation of
/// their own. Writes only ever come from the Settings picker, on the main thread.
@Observable
final class TypographyPreference {
    nonisolated(unsafe) static let shared = TypographyPreference()

    var style: TypographyStyle { didSet { UserDefaults.standard.set(style.rawValue, forKey: "typography") } }

    private init() {
        // SF Pro is the default: matching the system typeface is what makes the app read as
        // part of iOS rather than as a visitor.
        style = TypographyStyle(rawValue: UserDefaults.standard.string(forKey: "typography") ?? "")
            ?? .system
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
