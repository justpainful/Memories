import SwiftData
import SwiftUI

/// Search without a server.
///
/// Everything here is answerable from metadata the library already has: dates, kinds,
/// favourites, places, collections. Understanding what is *in* a picture is a later
/// problem, and pretending to do it now would mean sending photos somewhere.
struct SearchView: View {
    @Environment(\.app) private var app

    @State private var query = ""
    @State private var results: [AssetRecord] = []
    @State private var matchedCollections: [CollectionRecord] = []
    @State private var interpretation: String?
    @State private var isSearching = false
    @State private var selection = PhotoSelection()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if query.isEmpty {
                    suggestions
                } else {
                    if let interpretation {
                        Text(interpretation)
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, Space.gutter)
                    }

                    if !matchedCollections.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("Collections").overlineStyle().padding(.horizontal, Space.gutter)
                            ForEach(matchedCollections) { collection in
                                NavigationLink {
                                    CollectionDetailView(collection: collection)
                                } label: {
                                    HStack {
                                        Text(collection.name)
                                            .font(Typo.label)
                                            .foregroundStyle(Palette.textPrimary)
                                        Spacer()
                                        Text("\(collection.itemCount)")
                                            .font(Typo.meta)
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                    .padding(.horizontal, Space.gutter)
                                    // A row of type is fifteen points tall and the gap between
                                    // its two ends is not part of it at all: without these the
                                    // only place the row could be hit was the letters.
                                    .padding(.vertical, Space.m)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    AssetGridView(
                        records: results,
                        emptyTitle: "Nothing matched",
                        emptyDetail: "Try a date, a year, a place, or a kind like “videos”.",
                        emptySymbol: "magnifyingglass",
                        isLoading: isSearching,
                        selection: selection
                    )
                }
            }
            .padding(.top, Space.s)
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .selectionActionBar(selection)
        .background(Palette.canvas)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Date, month, year, place, or kind")
        // Every keystroke used to read the whole library on the main thread and sort it. At
        // fifteen thousand rows that is the keyboard locking up between letters, and typing
        // "August" paid for it six times. Waiting for a pause in the typing — and cancelling
        // the wait when another letter lands — turns those six passes into one.
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                clear()
                return
            }
            isSearching = true
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            run()
            isSearching = false
        }
    }

    /// Today's date leads, because a day typed without a year searches every year — one tap is
    /// the shortest route to this date through the whole library.
    private var hints: [String] {
        [Date.now.formatted(.dateTime.month(.wide).day()),
         "2024", "August", "Videos", "Live Photos", "Screenshots", "Favourites"]
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Try").overlineStyle().padding(.bottom, Space.s)
            ForEach(hints, id: \.self) { hint in
                Button { query = hint } label: {
                    HStack(spacing: Space.m) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textTertiary)
                        Text(hint).font(Typo.label).foregroundStyle(Palette.textPrimary)
                        Spacer()
                    }
                    // The row spans the screen but only the glyph and the word were ever
                    // drawn, and a button is hit where it is drawn — so everything to the
                    // right of the word was dead. A single line of type is not 44 points
                    // tall either, which is the other half of why these were hard to press.
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    // MARK: Query

    private func clear() {
        results = []
        matchedCollections = []
        interpretation = nil
        isSearching = false
        // A selection made in one set of results means nothing in the next, and one that
        // survives the query that produced it is how a batch lands on the wrong photographs.
        selection.end()
    }

    private func run() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }

        let context = app.container.mainContext
        let lowered = trimmed.lowercased()
        let calendar = Calendar.current
        var options = CurationOptions.browsing
        var described: [String] = []

        // Kind
        if lowered.contains("video") { options.media = .videos; described.append("videos") }
        else if lowered.contains("live") { options.media = .livePhotos; described.append("Live Photos") }
        else if lowered.contains("screenshot") { options.media = .screenshots; described.append("screenshots") }
        else if lowered.contains("photo") { options.media = .photos; described.append("photos") }

        let date = DateTerms(text: lowered, calendar: calendar)

        // A named day is narrow enough to fetch by date span, which lets the momentDate index
        // do the work. A bare month or year would touch most of the library either way, so those
        // stay filters over everything.
        var pool: [AssetRecord]
        if date.namesADay {
            let spans = date.dayIntervals(calendar: calendar,
                                          yearsBack: libraryReach(context: context, calendar: calendar))
            pool = LibraryQuery.assets(in: spans, options: options, context: context)
        } else {
            pool = LibraryQuery.allRecords(context: context)
                .filter { LibraryQuery.passes($0, options: options) }
        }

        // Favourites — the user's own mark, in Photos or here.
        if lowered.contains("favourite") || lowered.contains("favorite") || lowered.contains("loved") {
            pool = pool.filter { $0.isFavoriteInPhotos || $0.isLoved }
            described.append("favourites")
        }

        // Date. A named day was already applied by the fetch above; a loose month or year narrows
        // the whole library here, because either can span all of it.
        if !date.namesADay {
            if let year = date.year {
                pool = pool.filter { calendar.component(.year, from: $0.momentDate) == year }
            }
            if let month = date.month {
                pool = pool.filter { calendar.component(.month, from: $0.momentDate) == month }
            }
        }
        if let phrase = date.phrase(calendar: calendar) { described.append(phrase) }

        // Place, matched against occasions that have been named
        let placeMatches = namedEventIdentifiers(matching: lowered, context: context)
        if !placeMatches.isEmpty {
            pool = pool.filter { placeMatches.contains($0.localIdentifier) }
            described.append("that place")
        }

        results = pool.sorted { $0.momentDate > $1.momentDate }
        // What was picked belonged to the last set of results; these are a different set.
        selection.clear()
        matchedCollections = collections(matching: lowered, context: context)
        interpretation = described.isEmpty
            ? "Showing everything that matched."
            : "Showing \(described.joined(separator: " · ")) — \(results.count) items."
    }

    /// How many years back the library actually goes.
    ///
    /// A day typed without a year means every one of them, so the search reaches as far as the
    /// photos do instead of stopping at the twenty years the other time windows assume.
    private func libraryReach(context: ModelContext, calendar: Calendar) -> Int {
        guard let oldest = LibraryQuery.allRecords(context: context, newestFirst: false, limit: 1).first
        else { return 0 }
        let earliest = calendar.component(.year, from: oldest.momentDate)
        return max(0, calendar.component(.year, from: .now) - earliest)
    }

    private func namedEventIdentifiers(matching term: String, context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<EventCluster>()
        guard let events = try? context.fetch(descriptor) else { return [] }
        let matching = events.filter { ($0.placeName ?? "").lowercased().contains(term) }
        return Set(matching.flatMap(\.assetIdentifiers))
    }

    private func collections(matching term: String, context: ModelContext) -> [CollectionRecord] {
        let descriptor = FetchDescriptor<CollectionRecord>(
            sortBy: [SortDescriptor(\CollectionRecord.sortIndex)]
        )
        guard let all = try? context.fetch(descriptor) else { return [] }
        return all.filter { $0.name.lowercased().contains(term) }
    }
}

// MARK: - Date terms

/// A date pulled out of whatever the user typed.
///
/// The three parts are found independently, because people write them in whichever order
/// occurs to them and usually leave one out — "7 August", "Aug 7 2024", "2024-08-07",
/// "August". A missing part widens the search instead of failing it.
private struct DateTerms {
    var year: Int?
    var month: Int?
    var day: Int?

    /// Wide enough for scanned family photographs, narrow enough that a stray number in a
    /// place name is not mistaken for a year.
    private static let plausibleYears = 1900...2200
    private static let ordinals = ["st", "nd", "rd", "th"]

    init(text: String, calendar: Calendar) {
        // Numbers are set aside and read last. Until the whole query has been seen there is no
        // way to tell whether the 7 in "7 August" is a day or noise.
        var numbers: [Int] = []

        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "/" }) {
            if let written = Self.numericDate(token) {
                year = written.year
                month = written.month
                day = written.day
            } else if let named = Self.monthIndex(token, calendar: calendar) {
                month = month ?? named
            } else if let number = Self.number(token) {
                numbers.append(number)
            }
        }

        for number in numbers where Self.plausibleYears.contains(number) {
            year = year ?? number
        }
        // A loose number only becomes a day once a month is on the table. On its own it is far
        // more likely to belong to a place or a collection name, and it never meant a date before.
        if month != nil {
            for number in numbers where (1...31).contains(number) {
                day = day ?? number
            }
        }
    }

    /// True once there is a single day to look at rather than a whole month or year.
    var namesADay: Bool { month != nil && day != nil }

    /// The spans to fetch for a named day. Without a year the day is shown in every year the
    /// library holds — this app is about time, so "the 7th of August" means all of them.
    func dayIntervals(calendar: Calendar, yearsBack: Int) -> [DateInterval] {
        guard let month, let day else { return [] }
        guard let year else {
            return TimeWindow.dayAcrossYears(month: month, day: day)
                .intervals(calendar: calendar, yearsBack: yearsBack)
        }
        return [calendar.interval(year: year, month: month, day: day)].compactMap { $0 }
    }

    /// What was understood, for the line above the results.
    func phrase(calendar: Calendar) -> String? {
        if let month, let day {
            let named = TimeWindow.dayAcrossYears(month: month, day: day)
            guard let year else { return "\(named.title) in every year" }
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = calendar.date(from: components) else { return named.title }
            return date.formatted(.dateTime.day().month(.wide).year())
        }

        var parts: [String] = []
        if let month, calendar.monthSymbols.indices.contains(month - 1) {
            parts.append(calendar.monthSymbols[month - 1])
        }
        if let year { parts.append(String(year)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "2024-08-07" — the one all-numeric spelling whose order is not in doubt. Something like
    /// "8/7" is deliberately left alone, because half the world reads it the other way round.
    private static func numericDate(_ token: Substring) -> (year: Int, month: Int, day: Int?)? {
        let parts = token.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard (2...3).contains(parts.count), parts[0].count == 4,
              let year = Int(parts[0]), plausibleYears.contains(year),
              let month = Int(parts[1]), (1...12).contains(month)
        else { return nil }

        guard parts.count == 3 else { return (year, month, nil) }
        guard let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        return (year, month, day)
    }

    /// Full names are matched inside the token, so "august2024" still reads as August.
    /// Abbreviations have to be the whole token, or "mar" would fire on "marathon".
    private static func monthIndex(_ token: Substring, calendar: Calendar) -> Int? {
        let word = String(token)
        if let index = calendar.monthSymbols.firstIndex(where: { word.contains($0.lowercased()) }) {
            return index + 1
        }
        if let index = calendar.shortMonthSymbols.firstIndex(where: { word == $0.lowercased() }) {
            return index + 1
        }
        return nil
    }

    private static func number(_ token: Substring) -> Int? {
        let digits = token.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        // "7th August" is how a great many people type a date.
        let tail = token.dropFirst(digits.count)
        guard tail.isEmpty || ordinals.contains(String(tail)) else { return nil }
        return Int(digits)
    }
}
