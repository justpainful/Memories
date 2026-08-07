import CoreLocation
import SwiftData
import SwiftUI

/// "Best of…" as something the user asks for, rather than something the engine decides to
/// hand them on the feed.
///
/// Every row here means the same thing — *the strongest frames inside this* — so the screen
/// is a list of ways to say "in here": a stretch of time, a trip, a place, an occasion. The
/// ranking is the one the rest of the app already uses; nothing new is computed per scope.
struct BestOfView: View {
    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset

    @State private var trips: [Trip] = []
    @State private var places: [PlaceScope] = []
    @State private var occasions: [EventCluster] = []
    /// Distinguishes "no trips found" from "there is nothing to look for trips in", which the
    /// two footers below have to tell apart to stay honest.
    @State private var hasLocatedEvents = false

    /// The four spans people name out loud. The longer historical windows belong to Explore
    /// Time; asking for "the best of five years ago" is a different question.
    private static let timeScopes: [TimeWindow] = [.today, .thisWeek, .thisMonth, .thisYear]

    var body: some View {
        List {
            Section("Time") {
                ForEach(Self.timeScopes) { window in
                    NavigationLink {
                        BestOfResultsScreen(title: "Best of \(window.title)",
                                            source: .window(window))
                    } label: {
                        ScopeRow(symbol: symbol(for: window), title: window.title)
                    }
                }
            }

            // The three sections below used to say what they had to say in their *footers*, and
            // a footer with no rows above it is not a section — it is a grey paragraph floating
            // under a heading. On a first run, when all three are empty, the screen came out as
            // one properly drawn list called Time followed by three loose sentences, which
            // reads as a screen that failed to finish rather than as one with nothing in it
            // yet. An empty section now carries a real row saying so, so every heading on the
            // screen is followed by the same kind of thing.
            Section {
                if trips.isEmpty {
                    EmptyScopeRow(symbol: "airplane", title: "No trips yet", detail: tripsDetail)
                } else {
                    ForEach(trips) { trip in
                        NavigationLink {
                            BestOfResultsScreen(title: trip.title,
                                                source: .identifiers(trip.assetIdentifiers))
                        } label: {
                            ScopeRow(coverIdentifier: trip.coverIdentifier,
                                     title: trip.title,
                                     detail: sideBySide(dateRangeText(trip.startDate, trip.endDate),
                                                        momentsText(trip.assetIdentifiers.count)))
                        }
                    }
                }
            } header: {
                Text("Trips")
            }

            Section {
                if places.isEmpty {
                    EmptyScopeRow(
                        symbol: "mappin.and.ellipse",
                        title: "No places yet",
                        detail: "Places are named from the coordinates your camera saved. None have been worked out yet."
                    )
                } else {
                    ForEach(places) { place in
                        NavigationLink {
                            BestOfResultsScreen(title: "Best of \(place.name)",
                                                source: .identifiers(place.assetIdentifiers))
                        } label: {
                            ScopeRow(coverIdentifier: place.coverIdentifier,
                                     title: place.name,
                                     detail: momentsText(place.assetIdentifiers.count))
                        }
                    }
                }
            } header: {
                Text("Places")
            }

            Section {
                if occasions.isEmpty {
                    EmptyScopeRow(
                        symbol: "calendar",
                        title: "No occasions yet",
                        detail: "Occasions appear once the library has been read through."
                    )
                } else {
                    ForEach(occasions) { event in
                        NavigationLink {
                            BestOfResultsScreen(title: title(for: event),
                                                source: .identifiers(event.assetIdentifiers))
                        } label: {
                            ScopeRow(coverIdentifier: event.coverIdentifier,
                                     title: title(for: event),
                                     detail: sideBySide(event.startDate.formatted(date: .abbreviated, time: .omitted),
                                                        momentsText(event.assetCount)))
                        }
                    }
                }
            } header: {
                Text("Occasions")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
        // A list of rows with a thumbnail on one side and a chevron on the other is unreadable
        // when the two are a foot apart, which is what the full width of an iPad does to it.
        .readableMeasure()
        .navigationTitle("Best Of")
        .navigationBarTitleDisplayMode(.inline)
        // Finding trips means reading every occasion in the library and its cover frame.
        // Yielding first keeps that out of the push animation.
        .task {
            await Task.yield()
            load()
        }
    }

    private var tripsDetail: String {
        hasLocatedEvents
            ? "Nothing in your library sits far enough from where you normally photograph to count as a trip."
            : "Trips are worked out from photo locations. None of your photos have a location saved, so there are none to find."
    }

    private func symbol(for window: TimeWindow) -> String {
        switch window {
        case .today:     return "sun.max"
        case .thisWeek:  return "calendar"
        case .thisMonth: return "calendar.badge.clock"
        default:         return "calendar.circle"
        }
    }

    private func title(for event: EventCluster) -> String {
        event.placeName ?? event.startDate.formatted(.dateTime.weekday(.wide))
    }

    private func momentsText(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "moment" : "moments")"
    }

    /// Two facts on one line, each fenced off from the other.
    ///
    /// The middle dot is bidi-neutral: it takes its direction from whatever is around it, so a
    /// place name in a right-to-left script beside a run of digits can end up on the wrong side
    /// of its own separator, and the row above it can resolve the other way. The isolates mark
    /// where each run starts and stops, so neither can drag the other across.
    private func sideBySide(_ leading: String, _ trailing: String) -> String {
        "\u{2068}\(leading)\u{2069} · \u{2068}\(trailing)\u{2069}"
    }

    private func load() {
        let context = app.container.mainContext
        let descriptor = FetchDescriptor<EventCluster>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let events = (try? context.fetch(descriptor)) ?? []
        hasLocatedEvents = events.contains { $0.latitude != nil && $0.longitude != nil }

        // Every occasion already elected a cover during indexing. Fetching all of them once
        // lets `Curator.cover` choose between them for a trip or a place without a fetch per
        // row, which at a few hundred occasions is the difference between instant and not.
        let coverRecords = LibraryQuery.records(for: events.compactMap(\.coverIdentifier),
                                                context: context)
        let byIdentifier = Dictionary(coverRecords.map { ($0.localIdentifier, $0) },
                                      uniquingKeysWith: { first, _ in first })

        func bestCover(among group: [EventCluster]) -> String? {
            let candidates = group.compactMap(\.coverIdentifier).compactMap { byIdentifier[$0] }
            return Curator.cover(for: candidates)?.localIdentifier
        }

        trips = TripFinder.trips(from: events, cover: bestCover)
        places = placeScopes(from: events, cover: bestCover)
        // An occasion of three frames has no best in it, and a list of them would bury the
        // evenings that do.
        occasions = Array(
            events.filter { $0.assetCount >= 4 }
                .sorted { $0.significance > $1.significance }
                .prefix(24)
        )
    }

    private func placeScopes(from events: [EventCluster],
                             cover: ([EventCluster]) -> String?) -> [PlaceScope] {
        let named = events.filter { $0.placeName != nil }
        let scopes = Dictionary(grouping: named) { $0.placeName ?? "" }
            .map { name, group in
                PlaceScope(name: name,
                           assetIdentifiers: group.flatMap(\.assetIdentifiers),
                           coverIdentifier: cover(group))
            }
            .filter { $0.assetIdentifiers.count >= 4 }
            .sorted { $0.assetIdentifiers.count > $1.assetIdentifiers.count }
        return Array(scopes.prefix(20))
    }
}

// MARK: - Trips

/// One run of time spent away from home, gathered from the occasions inside it.
struct Trip: Identifiable {
    let id: UUID
    let placeName: String?
    let startDate: Date
    let endDate: Date
    let assetIdentifiers: [String]
    let coverIdentifier: String?

    /// Named for where it happened when that is known. A trip whose places have not been
    /// reverse-geocoded yet still has its dates, which is enough to recognise it by.
    var title: String { placeName ?? "Away" }
}

/// Finds trips in the occasions the indexer already produced.
///
/// The app has no travel history, no calendar access and no network, so a trip has to be
/// inferred from the coordinates the camera saved. The definition used here is stated in
/// full, because a looser one turns every ordinary weekend into a "trip":
///
/// **A trip is a run of `EventCluster`s that spans at least two calendar days and happened
/// away from the user's home area.**
///
/// - *Home area* is the median latitude and the median longitude of every located event,
///   taken separately. The median rather than the mean because a single month abroad drags
///   an average halfway across a continent, while the median stays where the ordinary days
///   are — and ordinary days are, by count, most of them.
/// - *Away* is further than ``awayRadius`` from that point. A hundred kilometres is beyond
///   the range of a normal day's photographing almost anywhere, and comfortably inside the
///   distance at which a person would say they went somewhere.
/// - Away occasions less than ``maxGap`` apart are merged, so a fortnight abroad arrives as
///   one trip rather than fourteen, and an evening indoors mid-journey does not split it.
/// - The two-calendar-day span is measured across the merged run, which is what separates a
///   trip from a long drive there and back.
///
/// A library with no coordinates has no home area, so it has no trips, and this returns
/// nothing. `BestOfView` says as much in its empty state; inferring trips from dates alone
/// would be inventing them.
enum TripFinder {
    /// Far enough that it is not somewhere the user could have been on an ordinary day.
    static let awayRadius: CLLocationDistance = 100_000
    /// Two away occasions closer together than this belong to the same journey.
    static let maxGap: TimeInterval = 2 * 24 * 60 * 60

    /// - Parameter cover: picks the frame that represents a run of occasions. Passed in
    ///   rather than computed here because choosing it means reading asset rows, and this
    ///   type only knows about geography.
    static func trips(from events: [EventCluster],
                      cover: ([EventCluster]) -> String?) -> [Trip] {
        let located = events
            .filter { $0.latitude != nil && $0.longitude != nil }
            .sorted { $0.startDate < $1.startDate }
        guard let home = homeArea(of: located) else { return [] }

        let away = located.filter { event in
            guard let latitude = event.latitude, let longitude = event.longitude else { return false }
            return CLLocation(latitude: latitude, longitude: longitude).distance(from: home) > awayRadius
        }

        var runs: [[EventCluster]] = []
        for event in away {
            if let previous = runs.last?.last,
               event.startDate.timeIntervalSince(previous.endDate) < maxGap {
                runs[runs.count - 1].append(event)
            } else {
                runs.append([event])
            }
        }

        return runs.compactMap { trip(from: $0, cover: cover) }
            .sorted { $0.startDate > $1.startDate }
    }

    private static func trip(from run: [EventCluster],
                             cover: ([EventCluster]) -> String?) -> Trip? {
        guard let first = run.first, let last = run.last else { return nil }
        let calendar = Calendar.current
        guard !calendar.isDate(first.startDate, inSameDayAs: last.endDate) else { return nil }

        return Trip(
            id: first.id,
            placeName: dominantPlaceName(in: run),
            startDate: first.startDate,
            endDate: last.endDate,
            assetIdentifiers: run.flatMap(\.assetIdentifiers),
            coverIdentifier: cover(run)
        )
    }

    /// Where the user normally photographs.
    ///
    /// Latitude and longitude are taken independently, which is not the true geometric
    /// median but costs one sort each and is wrong only for someone whose life is split
    /// evenly between two distant places — and for them, either answer is arguable.
    private static func homeArea(of events: [EventCluster]) -> CLLocation? {
        guard let latitude = median(events.compactMap(\.latitude)),
              let longitude = median(events.compactMap(\.longitude))
        else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// The place the trip was mostly about, weighted by how much was shot there, so a night
    /// in a town on the way does not get to name a week on the coast.
    private static func dominantPlaceName(in run: [EventCluster]) -> String? {
        var weight: [String: Int] = [:]
        for event in run {
            guard let name = event.placeName else { continue }
            weight[name, default: 0] += event.assetCount
        }
        return weight.max { $0.value < $1.value }?.key
    }
}

// MARK: - Places

/// One place, with everything photographed there gathered together.
private struct PlaceScope: Identifiable {
    let name: String
    let assetIdentifiers: [String]
    let coverIdentifier: String?

    var id: String { name }
}

// MARK: - Results

private enum BestOfSource {
    case window(TimeWindow)
    case identifiers([String])
}

/// What a scope holds, once the ranking has had its say.
private struct BestOfResultsScreen: View {
    let title: String
    let source: BestOfSource

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true

    var body: some View {
        AssetCollectionScreen(
            title: title,
            records: records,
            emptyTitle: "Nothing to choose from",
            emptyDetail: "There are no photos here yet.",
            isLoading: isLoading
        )
        // Ranking a whole year takes long enough to be seen. Yielding first lets the push
        // land on an empty grid rather than on "nothing to choose from", which is a different
        // claim and, for the moment it is on screen, an untrue one.
        .task {
            await Task.yield()
            load()
        }
    }

    private func load() {
        // Curated even for someone who browses in Pure: "best of" is a judgement by
        // definition, and without one this screen would just be the whole span again.
        var options = app.settings.curationOptions
        options.mode = .smart

        let context = app.container.mainContext
        let pool: [AssetRecord]
        switch source {
        case .window(let window):
            pool = LibraryQuery.assets(in: window.intervals(), options: options, context: context)
        case .identifiers(let identifiers):
            pool = LibraryQuery.records(for: identifiers, context: context)
                .filter { LibraryQuery.passes($0, options: options) }
        }

        let curated = Curator.curate(pool, options: options)
        records = Array(
            curated.sorted { $0.memoryScore > $1.memoryScore }.prefix(keepCount(of: curated.count))
        )
        isLoading = false
    }

    /// A best-of that shows nearly everything is not a best-of. Keep the strongest third,
    /// but never so few that a quiet day has nothing in it, and never a screen-full of sixty.
    private func keepCount(of total: Int) -> Int {
        min(60, max(6, total / 3))
    }
}

// MARK: - Rows

/// One way in. Occasions and places lead with their own cover; spans of time have none yet,
/// so they lead with a symbol rather than a placeholder pretending to be a photograph.
private struct ScopeRow: View {
    var symbol: String?
    var coverIdentifier: String?
    let title: String
    var detail: String?

    /// The symbol column and the cover both grow with the type beside them. Frozen, a 16-point
    /// glyph rendered at an accessibility size hangs out of a 26-point slot on both sides and
    /// lands on the first word of the title; a 52-point cover next to a 40-point line of text
    /// stops reading as the thing the row is about.
    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 26
    @ScaledMetric(relativeTo: .subheadline) private var coverSide: CGFloat = 52

    var body: some View {
        HStack(spacing: Space.l) {
            if let coverIdentifier {
                PhotoThumbnail(identifier: coverIdentifier, side: coverSide, radius: Radius.thumb)
                    .accessibilityHidden(true)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(Typo.scaled(16, .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: iconColumn)
                    // Otherwise every row on the screen is read out as its SF Symbol name
                    // before the words that actually name it: "sun dot max, Today".
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: Radius.thumb)
                    .fill(Palette.surfaceSunk)
                    .frame(width: coverSide, height: coverSide)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Place names, trip names and occasion names are whatever the world and the
                // user called them, so they are allowed a second line and a little shrinking
                // before anything is cut off.
                Text(title)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let detail {
                    Text(detail)
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Hit.min)
        // One row, one thing said: the name and then what is in it, rather than three separate
        // elements to swipe through.
        .accessibilityElement(children: .combine)
    }
}

/// What a section says when it has nothing in it yet.
///
/// Shaped like `ScopeRow` on purpose. The point is not the wording — it is that an empty
/// section still draws a row, so the heading above it is followed by the same grouped surface
/// as every other heading on the screen instead of by bare text on the canvas.
private struct EmptyScopeRow: View {
    let symbol: String
    let title: String
    let detail: String

    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            Image(systemName: symbol)
                .font(Typo.scaled(16, .medium))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: iconColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Text(detail)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: Hit.min)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

/// "Aug 12 – 19, 2024". The interval style collapses whatever the two ends share, which is
/// usually the month and always the year.
private func dateRangeText(_ start: Date, _ end: Date) -> String {
    guard end > start else { return start.formatted(date: .abbreviated, time: .omitted) }
    return (start..<end).formatted(date: .abbreviated, time: .omitted)
}
