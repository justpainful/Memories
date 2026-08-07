import Photos
import SwiftData
import SwiftUI

/// Direct access by kind, plus the surfaces that do not deserve a tab of their own.
struct LibraryView: View {
    @Environment(\.app) private var app
    @State private var counts: [MediaFilter: Int] = [:]
    @State private var hiddenCount = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(MediaFilter.allCases, id: \.self) { filter in
                        NavigationLink {
                            MediaKindScreen(filter: filter)
                        } label: {
                            LibraryRow(symbol: symbol(for: filter),
                                       title: filter.title,
                                       count: counts[filter])
                        }
                    }
                }

                Section {
                    NavigationLink { CollectionsView() } label: {
                        LibraryRow(symbol: "folder", title: "Collections", count: nil)
                    }
                    NavigationLink { HiddenMemoriesView() } label: {
                        LibraryRow(symbol: "eye.slash", title: "Hidden", count: hiddenCount)
                    }
                }

                Section {
                    NavigationLink { BestOfView() } label: {
                        LibraryRow(symbol: "trophy", title: "Best Of", count: nil)
                    }
                    NavigationLink { PeopleView() } label: {
                        LibraryRow(symbol: "person.2", title: "People", count: nil)
                    }
                    NavigationLink { CalendarView() } label: {
                        LibraryRow(symbol: "calendar", title: "Calendar", count: nil)
                    }
                    NavigationLink { PlacesView() } label: {
                        LibraryRow(symbol: "map", title: "Places", count: nil)
                    }
                    NavigationLink { SearchView() } label: {
                        LibraryRow(symbol: "magnifyingglass", title: "Search", count: nil)
                    }
                }

                Section {
                    NavigationLink { SettingsView() } label: {
                        LibraryRow(symbol: "gearshape", title: "Settings", count: nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .contentMargins(.bottom, 132, for: .scrollContent)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { load() }
        .onChange(of: app.library.changeGeneration) { _, _ in load() }
    }

    private func symbol(for filter: MediaFilter) -> String {
        switch filter {
        case .all:         return "square.stack"
        case .photos:      return "photo"
        case .videos:      return "video"
        case .livePhotos:  return "livephoto"
        case .screenshots: return "camera.viewfinder"
        }
    }

    /// Six numbers, none of which need a photo.
    ///
    /// `CurationOptions.browsing` admits screenshots, screen recordings, downloads and
    /// cloud-only assets, so for these four `LibraryQuery.passes` reduces to "not hidden, and
    /// the right media type" — a question SQLite answers with a count instead of fifteen
    /// thousand objects.
    private func load() {
        let context = app.container.mainContext
        let photo = PHAssetMediaType.image.rawValue
        let video = PHAssetMediaType.video.rawValue

        hiddenCount = count(#Predicate<AssetRecord> { $0.excludedFromMemories }, in: context)
        counts[.all] = count(#Predicate<AssetRecord> { $0.excludedFromMemories == false },
                             in: context)
        counts[.photos] = count(#Predicate<AssetRecord> {
            $0.excludedFromMemories == false && $0.mediaTypeRaw == photo
        }, in: context)
        counts[.videos] = count(#Predicate<AssetRecord> {
            $0.excludedFromMemories == false && $0.mediaTypeRaw == video
        }, in: context)

        let container = app.container
        Task { @MainActor in
            let subtypes = await SubtypeCounter(modelContainer: container).counts()
            counts[.livePhotos] = subtypes.live
            counts[.screenshots] = subtypes.screenshots
        }
    }

    private func count(_ predicate: Predicate<AssetRecord>, in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<AssetRecord>(predicate: predicate))) ?? 0
    }
}

/// The two counts that cannot be asked for.
///
/// Live Photo and screenshot are bits inside `mediaSubtypesRaw`, and `#Predicate` has no
/// bitwise operator, so these two genuinely need the rows in memory. One pass produces both,
/// on a background context, which is why they arrive a moment after the numbers above them.
@ModelActor
private actor SubtypeCounter {
    func counts() -> (live: Int, screenshots: Int) {
        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.excludedFromMemories == false }
        )
        guard let records = try? modelContext.fetch(descriptor) else { return (0, 0) }

        var live = 0
        var screenshots = 0
        for record in records {
            if record.isLivePhoto { live += 1 }
            if record.isScreenshot { screenshots += 1 }
        }
        return (live, screenshots)
    }
}

private struct LibraryRow: View {
    let symbol: String
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 26)
            Text(title).font(Typo.label).foregroundStyle(Palette.textPrimary)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }
        }
    }
}

/// All / Photos / Videos / Live Photos / Screenshots.
struct MediaKindScreen: View {
    let filter: MediaFilter

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []

    var body: some View {
        AssetCollectionScreen(
            title: filter.title,
            records: records,
            emptyTitle: "No \(filter.title.lowercased()) yet"
        )
        .task { load() }
    }

    private func load() {
        var options = CurationOptions.browsing
        options.media = filter
        records = LibraryQuery.allRecords(context: app.container.mainContext)
            .filter { LibraryQuery.passes($0, options: options) }
    }
}

/// Hidden from Memories — with the point of the screen right on each tile: Restore.
struct HiddenMemoriesView: View {
    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Hidden photos stay in your library. They are only kept out of Memories, and you can restore any of them here.")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s)

                AssetGridView(
                    records: records,
                    emptyTitle: "Nothing is hidden",
                    emptyDetail: "Photos you hide from Memories will collect here.",
                    emptySymbol: "eye.slash",
                    trailingAction: { record in
                        AnyView(
                            Button {
                                app.feedback.setHiddenFromMemories(false, identifier: record.localIdentifier)
                                Haptics.impact(.light)
                                load()
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .font(.system(size: 19))
                                    .foregroundStyle(.white, Palette.accent)
                            }
                            .buttonStyle(.plain)
                        )
                    }
                )
            }
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Hidden Memories")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        var options = CurationOptions.browsing
        options.includeHiddenFromMemories = true
        records = LibraryQuery.allRecords(context: app.container.mainContext)
            .filter { $0.excludedFromMemories }
    }
}
