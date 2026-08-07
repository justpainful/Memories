import Foundation

/// The seven things that decide whether a memory is worth showing today.
///
/// Kept as named parts rather than one opaque number so the ranking can be reasoned about,
/// and so `recentExposure` can do its job: a memory you were shown yesterday has to be
/// genuinely better than the alternatives to earn its place again.
struct ScoreComponents: Sendable, Equatable {
    var relevance: Double = 0        // how strongly this window matches today
    var quality: Double = 0          // how good the frames in it actually are
    var novelty: Double = 0          // how long since these assets were last surfaced
    var timeSignificance: Double = 0 // round anniversaries and long gaps count for more
    var mediaDiversity: Double = 0   // a mix of stills and video reads richer than either alone
    var duplicateDensity: Double = 0 // penalised: near-identical frames padding the count
    var recentExposure: Double = 0   // penalised: shown recently

    var total: Double {
        let positive = relevance * 0.28
            + quality * 0.24
            + novelty * 0.16
            + timeSignificance * 0.14
            + mediaDiversity * 0.06
        let negative = duplicateDensity * 0.08 + recentExposure * 0.30
        return max(0, min(1, positive - negative + 0.06))
    }
}

/// A memory the engine is proposing, before anything has been shown to anyone.
struct MemoryCandidate: Sendable, Identifiable, Equatable {
    var id: String
    var kind: MemoryKind
    var title: String
    var subtitle: String?
    var referenceDate: Date
    var assetIdentifiers: [String]
    var coverIdentifier: String?
    var eventID: UUID?
    var placeName: String?
    var components: ScoreComponents
    /// Set after preference learning has had its say.
    var score: Double = 0

    var assetCount: Int { assetIdentifiers.count }

    /// How the feed should draw this: one big frame, a run of years, or a mosaic.
    var presentation: MemoryPresentation {
        if kind == .event && assetCount >= 5 { return .mosaic }
        if assetCount == 1 { return .single }
        switch kind {
        case .previousYears, .season: return .throughTheYears
        case .onThisDay:              return assetCount > 6 ? .throughTheYears : .mosaic
        case .bestOfMonth, .bestOfYear, .forgotten, .rediscovery: return .strip
        default:                      return assetCount >= 5 ? .mosaic : .strip
        }
    }
}

enum MemoryPresentation: Sendable {
    case single           // one photograph, full bleed
    case mosaic           // asymmetric cluster, one large and several small
    case strip            // horizontal run of cards
    case throughTheYears  // year-labelled columns
}

/// One year's worth of a "through the years" memory.
struct YearSlice: Sendable, Identifiable, Equatable {
    var id: Int { year }
    var year: Int
    var assetIdentifiers: [String]
    var coverIdentifier: String?
    var count: Int { assetIdentifiers.count }
}
