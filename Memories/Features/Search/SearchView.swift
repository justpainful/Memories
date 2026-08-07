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
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    AssetGridView(
                        records: results,
                        emptyTitle: "Nothing matched",
                        emptyDetail: "Try a year, a month, a place, or a kind like “videos”.",
                        emptySymbol: "magnifyingglass"
                    )
                }
            }
            .padding(.top, Space.s)
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Year, month, place, or kind")
        .onChange(of: query) { _, _ in run() }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Try").overlineStyle()
            ForEach(["2024", "August", "Videos", "Live Photos", "Screenshots", "Favourites"], id: \.self) { hint in
                Button { query = hint } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textTertiary)
                        Text(hint).font(Typo.label).foregroundStyle(Palette.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    // MARK: Query

    private func run() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            matchedCollections = []
            interpretation = nil
            return
        }

        let context = app.container.mainContext
        let lowered = trimmed.lowercased()
        var options = CurationOptions.browsing
        var described: [String] = []

        // Kind
        if lowered.contains("video") { options.media = .videos; described.append("videos") }
        else if lowered.contains("live") { options.media = .livePhotos; described.append("Live Photos") }
        else if lowered.contains("screenshot") { options.media = .screenshots; described.append("screenshots") }
        else if lowered.contains("photo") { options.media = .photos; described.append("photos") }

        var pool = LibraryQuery.allRecords(context: context)
            .filter { LibraryQuery.passes($0, options: options) }

        // Favourites — the user's own mark, in Photos or here.
        if lowered.contains("favourite") || lowered.contains("favorite") || lowered.contains("loved") {
            pool = pool.filter { $0.isFavoriteInPhotos || $0.isLoved }
            described.append("favourites")
        }

        // Year
        let calendar = Calendar.current
        if let year = Int(lowered.filter(\.isNumber)), (1900...2200).contains(year) {
            pool = pool.filter { calendar.component(.year, from: $0.creationDate) == year }
            described.append(String(year))
        }

        // Month by name
        let months = calendar.monthSymbols.map { $0.lowercased() }
        if let index = months.firstIndex(where: { lowered.contains($0) }) {
            pool = pool.filter { calendar.component(.month, from: $0.creationDate) == index + 1 }
            described.append(calendar.monthSymbols[index])
        }

        // Place, matched against occasions that have been named
        let placeMatches = namedEventIdentifiers(matching: lowered, context: context)
        if !placeMatches.isEmpty {
            pool = pool.filter { placeMatches.contains($0.localIdentifier) }
            described.append("that place")
        }

        results = pool.sorted { $0.creationDate > $1.creationDate }
        matchedCollections = collections(matching: lowered, context: context)
        interpretation = described.isEmpty
            ? "Showing everything that matched."
            : "Showing \(described.joined(separator: " · ")) — \(results.count) items."
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
