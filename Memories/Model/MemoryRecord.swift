import Foundation
import SwiftData

/// Every shape of memory the engine knows how to propose.
enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case onThisDay
    case thisWeek
    case previousYears
    case event
    case place
    case forgotten
    case bestOfMonth
    case bestOfYear
    case season
    case random
    case rediscovery
    /// Strong photographs the engine keeps passing over. Distinct from `forgotten`, which is
    /// about age: these can be recent and still never have had their turn.
    case rarelySeen

    /// The editorial voice differs per kind; this is the fallback when nothing better fits.
    var fallbackTitle: String {
        switch self {
        case .onThisDay:     return "On this day"
        case .thisWeek:      return "This week"
        case .previousYears: return "Through the years"
        case .event:         return "An occasion"
        case .place:         return "A place you know"
        case .forgotten:     return "Long unseen"
        case .bestOfMonth:   return "Best of the month"
        case .bestOfYear:    return "Best of the year"
        case .season:        return "This season, before"
        case .random:        return "Something from your library"
        case .rediscovery:   return "Recently rediscovered"
        case .rarelySeen:    return "Rarely seen"
        }
    }
}

/// A memory the engine actually decided to show, plus how the user has reacted to it.
///
/// Reactions are what stop the feed repeating itself: a memory shown today needs a reason
/// to come back tomorrow, and one that was dismissed needs a stronger reason still.
@Model
final class MemoryRecord {
    #Unique<MemoryRecord>([\.key])
    #Index<MemoryRecord>([\.referenceDate], [\.generatedAt])

    var id: UUID = UUID()
    /// The candidate identity the engine generates, e.g. `onThisDay-2024`. Stable across
    /// regenerations, which is what lets a memory keep its history when it reappears.
    var key: String = ""
    var kindRaw: String = MemoryKind.random.rawValue
    var title: String = ""
    var subtitle: String?
    /// The date the memory is *about*, which is rarely the date it was generated.
    var referenceDate: Date = Date.now
    var assetIdentifiers: [String] = []
    var coverIdentifier: String?
    var score: Double = 0
    var generatedAt: Date = Date.now

    /// Set when this memory belongs to one recognised occasion or place.
    var eventClusterID: UUID?
    var placeName: String?

    // Exposure and reaction
    var shownAt: Date?
    var shownCount: Int = 0
    var opened: Bool = false
    var dismissed: Bool = false
    var saved: Bool = false

    init(key: String, kind: MemoryKind, title: String, referenceDate: Date, assetIdentifiers: [String]) {
        self.key = key
        self.kindRaw = kind.rawValue
        self.title = title
        self.referenceDate = referenceDate
        self.assetIdentifiers = assetIdentifiers
    }

    var kind: MemoryKind { MemoryKind(rawValue: kindRaw) ?? .random }
    var assetCount: Int { assetIdentifiers.count }
}

/// How often a memory or an asset has been put in front of the user, and when.
///
/// Kept separate from `MemoryRecord` so exposure survives regeneration: the engine rebuilds
/// candidates freely, but what you have already seen is not forgotten along with them.
@Model
final class ExposureRecord {
    #Unique<ExposureRecord>([\.key])

    /// `kind:identifier`, e.g. `asset:ABC-123` or `memory:onThisDay-2024-08-07`.
    var key: String = ""
    var count: Int = 0
    var lastShownAt: Date = Date.distantPast
    var opened: Int = 0
    var dismissed: Int = 0

    init(key: String) {
        self.key = key
    }
}
