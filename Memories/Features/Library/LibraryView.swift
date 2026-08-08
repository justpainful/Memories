import Photos
import SwiftData
import SwiftUI

/// Direct access by kind, plus the surfaces that do not deserve a tab of their own.
struct LibraryView: View {
    @Environment(\.app) private var app
    /// What the floating tab bar actually measured, rather than the 132 this used to write.
    @Environment(\.bottomBarInset) private var bottomBarInset
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
            .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
            // This is a source list — nine short labels with a number at the end of each. Left
            // to fill an iPad it becomes a row whose label and count are a hand's width apart,
            // which is a table, not a list. The canvas is applied outside the cap so the page
            // is still the page; only the rows stop.
            .readableMeasure()
            .background(Palette.canvas)
            .markedNavigationBar("Library")
            .toolbar(.hidden, for: .tabBar)   // the app draws its own; see RootView.surface
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

    /// The symbol column grows with the label beside it. Frozen at twenty-six points it would
    /// be a glyph spilling over its own gutter and into the title as soon as the reader asked
    /// for larger text.
    @ScaledMetric(relativeTo: .callout) private var symbolColumn: CGFloat = 26
    /// Label and value on one line stop fitting long before the largest sizes, and this row has
    /// both plus a disclosure chevron the system draws.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        row
            // Nine rows, each of them a symbol the reader does not need named and a bare
            // integer that could be anything. Combined into one element it reads "Live Photos,
            // 412 items" rather than "livephoto, Live Photos, 412".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var row: some View {
        if typeSize.isAccessibilitySize {
            // At accessibility sizes the count goes under the title instead of fighting it for
            // the same line — the same thing Settings does with its own value rows.
            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    label
                    if count != nil { value }
                }
            }
        } else {
            HStack(spacing: Space.l) {
                icon
                label
                Spacer(minLength: Space.s)
                if count != nil { value }
            }
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(Typo.scaled(16, .medium))
            .foregroundStyle(Palette.accent)
            .frame(width: symbolColumn)
    }

    private var label: some View {
        Text(title)
            .font(Typo.label)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var value: some View {
        if let count {
            // `Text(_:format:)` rather than interpolation: a bare `"\(count)"` is ASCII digits
            // with no grouping, so a library of fifteen thousand reads "15234" beside dates
            // that are being formatted properly two rows away.
            Text(count, format: .number)
                .font(Typo.meta)
                .foregroundStyle(Palette.textTertiary)
                .monospacedDigit()
        }
    }

    private var accessibilityText: String {
        guard let count else { return title }
        return "\(title), \(count.formatted()) items"
    }
}

/// All / Photos / Videos / Live Photos / Screenshots.
struct MediaKindScreen: View {
    let filter: MediaFilter

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true

    var body: some View {
        AssetCollectionScreen(
            title: filter.title,
            records: records,
            emptyTitle: emptyTitle,
            isLoading: isLoading
        )
        // Reading the whole library is the better part of a second at this size, and the
        // screen is already on the way in. Yielding first lets the empty frame paint as an
        // empty grid rather than as "no photos" — and lets the push animation finish.
        .task {
            await Task.yield()
            load()
        }
    }

    /// The empty state, written out per kind rather than assembled.
    ///
    /// It used to be `"No \(filter.title.lowercased()) yet"`, which had three faults at once.
    /// `lowercased()` takes no locale, so it applies invariant casing rules — meaningless in a
    /// script without case and actively wrong in Turkish. It destroys Apple's own product
    /// capitalization: "Live Photos" is a name, and "No live photos yet" is wrong in English
    /// before it is wrong anywhere else. And a sentence glued together from a fragment and a
    /// noun can never be reordered by anyone translating it.
    private var emptyTitle: String {
        switch filter {
        case .all:         return "No photos yet"
        case .photos:      return "No photos yet"
        case .videos:      return "No videos yet"
        case .livePhotos:  return "No Live Photos yet"
        case .screenshots: return "No screenshots yet"
        }
    }

    private func load() {
        var options = CurationOptions.browsing
        options.media = filter
        records = LibraryQuery.allRecords(context: app.container.mainContext)
            .filter { LibraryQuery.passes($0, options: options) }
        isLoading = false
    }
}

/// Hidden from Memories — with the point of the screen right on each tile: Restore.
struct HiddenMemoriesView: View {
    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true
    @State private var selection = PhotoSelection()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Hidden photos stay in your library. They are only kept out of Memories, and you can restore any of them here.")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Prose, so it stops at a measure. The grid below it does not — pictures
                    // are looked at, and there is no such thing as too many of them across.
                    .readableMeasure()
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s)

                AssetGridView(
                    records: records,
                    emptyTitle: "Nothing is hidden",
                    emptyDetail: "Photos you hide from Memories will collect here.",
                    emptySymbol: "eye.slash",
                    isLoading: isLoading,
                    trailingAction: { record in
                        AnyView(
                            Button {
                                app.feedback.setHiddenFromMemories(false, identifier: record.localIdentifier)
                                Haptics.impact(.light)
                                load()
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    // `Typo.glyph`, which does not scale. This is drawn in the
                                    // corner of a thumbnail that cannot grow with it — at the
                                    // densest rung the tile is about fifty points across, and a
                                    // symbol at accessibility sizes would be wider than the
                                    // photograph and wider than its own touch area, so the
                                    // visible button would stop matching the region that
                                    // answers a finger. The word is on the label below.
                                    .font(Typo.glyph(19, .regular))
                                    .foregroundStyle(.white, Palette.accent)
                                    // The glyph is 19 points across. The touch has to be 44,
                                    // whatever is drawn inside it.
                                    .frame(width: Hit.min, height: Hit.min)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Restore to Memories")
                        )
                    },
                    selection: selection
                )
            }
            .padding(.bottom, bottomBarInset)
        }
        .scrollIndicators(.hidden)
        .selectionActionBar(selection)
        .background(Palette.canvas)
        .navigationTitle("Hidden Memories")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await Task.yield()
            load()
        }
    }

    private func load() {
        // `passes` is not consulted at all here: the one thing every row on this screen has in
        // common is the flag that keeps it out of everywhere else.
        records = LibraryQuery.allRecords(context: app.container.mainContext)
            .filter { $0.excludedFromMemories }
        isLoading = false
    }
}
