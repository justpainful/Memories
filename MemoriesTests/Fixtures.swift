import Foundation
import Photos
@testable import Memories

/// Deterministic material for the tests that follow.
///
/// Everything here is pinned: a Gregorian calendar in UTC with an explicit `firstWeekday`, and
/// dates written out in full. No test in this target may consult the machine's clock, and none
/// may depend on the region it happens to run in.
enum Fixture {

    // MARK: Time

    static func calendar(firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0,
                     in calendar: Calendar = Fixture.calendar()) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: Values

    static func clusterInput(_ identifier: String,
                             at date: Date,
                             latitude: Double? = nil,
                             longitude: Double? = nil,
                             burst: String? = nil,
                             isVideo: Bool = false,
                             vector: [Float]? = nil,
                             score: Double = 0.5) -> ClusterInput {
        ClusterInput(identifier: identifier,
                     date: date,
                     latitude: latitude,
                     longitude: longitude,
                     burstIdentifier: burst,
                     isVideo: isVideo,
                     featureVector: vector.map({ FeatureVector(values: $0) }),
                     memoryScore: score)
    }

    /// A row, built without a container. `AssetRecord` is a `@Model`, but an uninserted
    /// instance is an ordinary object, which is all the pure filters ever look at.
    static func asset(_ identifier: String,
                      at date: Date = Fixture.date(2024, 6, 15, 12),
                      score: Double = 0.8,
                      isScreenshot: Bool = false,
                      isVideo: Bool = false,
                      isLivePhoto: Bool = false,
                      isUtility: Bool = false,
                      hidden: Bool = false,
                      locallyAvailable: Bool = true,
                      bestInCluster: Bool = true,
                      eventID: UUID? = nil) -> AssetRecord {
        let record = AssetRecord(localIdentifier: identifier, creationDate: date)
        record.mediaTypeRaw = (isVideo ? PHAssetMediaType.video : PHAssetMediaType.image).rawValue

        var subtypes: PHAssetMediaSubtype = []
        if isScreenshot { subtypes.insert(.photoScreenshot) }
        if isLivePhoto { subtypes.insert(.photoLive) }
        record.mediaSubtypesRaw = Int(subtypes.rawValue)

        record.memoryScore = score
        record.isUtilityImage = isUtility
        record.excludedFromMemories = hidden
        record.isLocallyAvailable = locallyAvailable
        record.isBestInSimilarityCluster = bestInCluster
        record.eventClusterID = eventID
        return record
    }

    // MARK: Comparison

    /// Scores are blends of weighted terms, so equality between two of them is a statement
    /// about arithmetic rather than about intent.
    static func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
