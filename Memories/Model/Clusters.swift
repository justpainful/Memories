import Foundation
import SwiftData

/// A group of near-identical frames — the five shots you took of the same thing.
///
/// Nothing is ever deleted. One member is elected Best Shot and the rest simply stop
/// competing for space inside a memory; "Show all 5" brings them back.
@Model
final class SimilarityCluster {
    #Unique<SimilarityCluster>([\.id])

    var id: UUID = UUID()
    var representativeIdentifier: String = ""
    var memberIdentifiers: [String] = []
    var averageSimilarity: Double = 0
    var createdAt: Date = Date.now
    var analysisVersion: Int = 0

    init(id: UUID = UUID(), representativeIdentifier: String, memberIdentifiers: [String]) {
        self.id = id
        self.representativeIdentifier = representativeIdentifier
        self.memberIdentifiers = memberIdentifiers
    }

    var memberCount: Int { memberIdentifiers.count }
    var isTrueDuplicateSet: Bool { memberCount > 1 }
}

/// A stretch of shooting the app believes was one occasion — a dinner, a drive, an evening.
///
/// Derived from the gap between shots, the place, how densely you were shooting, and how
/// visually continuous the frames are, so 39 files become "Friday Night · 39 moments".
@Model
final class EventCluster {
    #Unique<EventCluster>([\.id])
    #Index<EventCluster>([\.startDate])

    var id: UUID = UUID()
    var startDate: Date = Date.distantPast
    var endDate: Date = Date.distantPast
    var assetIdentifiers: [String] = []
    var photoCount: Int = 0
    var videoCount: Int = 0
    var coverIdentifier: String?
    var placeName: String?
    var latitude: Double?
    var longitude: Double?
    /// How much this occasion stands out from ordinary days: density, duration, variety, quality.
    var significance: Double = 0
    var analysisVersion: Int = 0

    init(id: UUID = UUID(), startDate: Date, endDate: Date, assetIdentifiers: [String]) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.assetIdentifiers = assetIdentifiers
    }

    var assetCount: Int { assetIdentifiers.count }
    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    var spansMultipleDays: Bool {
        !Calendar.current.isDate(startDate, inSameDayAs: endDate)
    }
}
