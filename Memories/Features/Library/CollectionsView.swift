import SwiftData
import SwiftUI

/// "24 items", with the number formatted rather than interpolated.
///
/// A bare `"\(count)"` is ASCII digits with no grouping separator, which puts one numbering
/// convention next to the dates on the same screen, which use another. And a count with no
/// unit — "24" on its own — is read aloud by VoiceOver as a number that could mean anything.
private func itemPhrase(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count.formatted()) items"
}

/// Memories the user chose to keep.
///
/// Wider than an album on purpose: a collection can hold a whole occasion or a whole day,
/// not only loose files, so "Favourite Nights" can mean the nights rather than 200 photos.
struct CollectionsView: View {
    @Environment(\.app) private var app
    /// What the floating tab bar actually measured, rather than the 132 this used to write.
    @Environment(\.bottomBarInset) private var bottomBarInset
    @Query(sort: \CollectionRecord.sortIndex) private var collections: [CollectionRecord]
    @State private var isCreating = false
    @State private var newName = ""

    /// The cover grows with the two lines of type beside it, so a row at accessibility sizes is
    /// still a picture with a name against it rather than a stamp against a paragraph.
    @ScaledMetric(relativeTo: .subheadline) private var coverSide: CGFloat = 54

    var body: some View {
        Group {
            if collections.isEmpty {
                QuietStatusView(
                    title: "No collections yet",
                    detail: "Keep a memory, an occasion or a whole day here and it will stay put.",
                    symbol: "folder"
                )
            } else {
                List {
                    ForEach(collections) { collection in
                        NavigationLink {
                            CollectionDetailView(collection: collection)
                        } label: {
                            row(for: collection)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
                // A list of names and counts, capped and centred rather than stretched the
                // width of an iPad.
                .readableMeasure()
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New collection")
            }
        }
        .alert("New collection", isPresented: $isCreating) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    /// One collection, as a row.
    ///
    /// Combined into a single accessibility element: the cover is a photograph with nothing to
    /// name, and split across three children the row would read as a picture, a name and a
    /// bare integer rather than as "Favourite Nights, 24 items".
    private func row(for collection: CollectionRecord) -> some View {
        HStack(spacing: Space.l) {
            if let cover = collection.coverIdentifier {
                PhotoThumbnail(identifier: cover, side: coverSide, radius: Radius.thumb)
            } else {
                RoundedRectangle(cornerRadius: Radius.thumb)
                    .fill(Palette.surfaceSunk)
                    .frame(width: coverSide, height: coverSide)
                    .overlay {
                        Image(systemName: "folder")
                            .foregroundStyle(Palette.textTertiary)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                    // The name is whatever the user typed, so it is unbounded. Two lines that
                    // shrink slightly rather than one line that clips at the first word.
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(itemPhrase(collection.itemCount))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(collection.name), \(itemPhrase(collection.itemCount))")
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        let context = app.container.mainContext
        let collection = CollectionRecord(name: name)
        collection.sortIndex = collections.count
        context.insert(collection)
        context.saveIfNeeded()
    }

    private func delete(at offsets: IndexSet) {
        let context = app.container.mainContext
        for index in offsets { context.delete(collections[index]) }
        context.saveIfNeeded()
    }
}

struct CollectionDetailView: View {
    let collection: CollectionRecord

    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true
    @State private var selection = PhotoSelection()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                if !nonAssetItems.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Also kept")
                            .overlineStyle()
                            .accessibilityAddTraits(.isHeader)
                        ForEach(nonAssetItems) { item in
                            KeptItemRow(item: item)
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s)
                }

                AssetGridView(
                    records: records,
                    emptyTitle: "Nothing kept here yet",
                    // Apple names a control in prose rather than drawing it. A literal ••• has
                    // nothing for VoiceOver to say, and the app already calls that button
                    // "More" in its own accessibility labels — so the copy was contradicting
                    // the label.
                    emptyDetail: "Add a memory from the More menu.",
                    emptySymbol: "folder",
                    isLoading: isLoading,
                    selection: selection
                )
            }
            .padding(.bottom, bottomBarInset)
        }
        .scrollIndicators(.hidden)
        .selectionActionBar(selection)
        .background(Palette.canvas)
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await Task.yield()
            load()
        }
    }

    private var nonAssetItems: [CollectionItem] {
        collection.items.filter { $0.kind != .asset }
    }

    private func load() {
        records = LibraryQuery.records(for: collection.assetReferences,
                                       context: app.container.mainContext)
        isLoading = false
    }
}

// MARK: - What else a collection holds

/// One occasion, day or memory kept into a collection.
///
/// These are the reason `CollectionItemKind` exists — a collection can hold a whole evening or
/// a whole day, not only loose files — and they used to arrive here as a grey line of text
/// reading "An occasion". No cover, no count, not a button, nothing to tap: the user kept an
/// entire evening and got back a label. So the reference is resolved to the thing it names, the
/// row is drawn like every other row in the app, and it opens.
private struct KeptItemRow: View {
    let item: CollectionItem

    @Environment(\.app) private var app
    @ScaledMetric(relativeTo: .subheadline) private var coverSide: CGFloat = 54

    @State private var kept: KeptItem?

    var body: some View {
        Group {
            if let kept {
                if let destination = kept.destination {
                    NavigationLink {
                        view(for: destination)
                    } label: {
                        row(kept, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Nothing to open — see `KeptItem.resolve`. Still drawn as a row rather
                    // than as bare text, because it is still a thing the user kept.
                    row(kept, showsChevron: false)
                }
            } else {
                // One frame, while the reference is looked up. Deliberately silent: a spinner
                // for a single indexed fetch reads as trouble.
                Color.clear.frame(height: coverSide)
            }
        }
        .task { kept = KeptItem.resolve(item, context: app.container.mainContext) }
    }

    private func row(_ kept: KeptItem, showsChevron: Bool) -> some View {
        HStack(spacing: Space.l) {
            cover(kept)
            VStack(alignment: .leading, spacing: 2) {
                Text(kept.title)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                    // A place name or a memory headline is free text and can be any length.
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                if let detail = kept.detail {
                    Text(detail)
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Space.s)
            if showsChevron {
                // The auto-mirroring member of the family. `chevron.right` names a side of the
                // screen, and in a right-to-left layout the row flips while the glyph does not,
                // so the arrow ends up pointing back at the title it belongs to.
                Image(systemName: "chevron.forward")
                    .font(Typo.glyph(12))
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        // A row this tall is already past the minimum, but the floor is stated rather than
        // assumed: at the smallest text size the cover is what is holding it open.
        .frame(minHeight: Hit.min)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kept.detail.map { "\(kept.title), \($0)" } ?? kept.title)
    }

    @ViewBuilder
    private func cover(_ kept: KeptItem) -> some View {
        if let identifier = kept.coverIdentifier {
            PhotoThumbnail(identifier: identifier, side: coverSide, radius: Radius.thumb)
        } else {
            RoundedRectangle(cornerRadius: Radius.thumb)
                .fill(Palette.surfaceSunk)
                .frame(width: coverSide, height: coverSide)
                .overlay {
                    Image(systemName: kept.symbol)
                        .foregroundStyle(Palette.textTertiary)
                }
        }
    }

    @ViewBuilder
    private func view(for destination: KeptDestination) -> some View {
        switch destination {
        case .assets(let title, let identifiers):
            KeptAssetsScreen(title: title, identifiers: identifiers)
        case .memory(let candidate):
            MemoryDetailView(candidate: candidate)
        case .day(let month, let day):
            KeptDayScreen(month: month, day: day)
        }
    }
}

/// Where a kept row goes when it is tapped.
private enum KeptDestination {
    /// A fixed set of photographs — an occasion, or a memory whose record has gone.
    case assets(title: String, identifiers: [String])
    case memory(MemoryCandidate)
    case day(month: Int, day: Int)
}

/// A kept reference, resolved into something that can be drawn and opened.
private struct KeptItem {
    var symbol: String
    var title: String
    var detail: String?
    var coverIdentifier: String?
    /// Nil when the reference no longer names anything — the occasion was re-clustered by a
    /// later indexing pass, or the day was written by a build that stored its display title
    /// rather than its date. The row is still drawn; it simply does not lead anywhere.
    var destination: KeptDestination?

    static func resolve(_ item: CollectionItem, context: ModelContext) -> KeptItem {
        switch item.kind {
        case .asset:
            // Assets are drawn in the grid below, not in this list.
            return KeptItem(symbol: "photo", title: "A photograph", detail: nil,
                            coverIdentifier: item.reference, destination: nil)

        case .event:
            guard let id = UUID(uuidString: item.reference),
                  let event = fetchEvent(id, context: context) else {
                return KeptItem(symbol: "calendar.badge.clock", title: "An occasion",
                                detail: "No longer in your library", coverIdentifier: nil,
                                destination: nil)
            }
            let title = event.placeName
                ?? event.startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            return KeptItem(
                symbol: "calendar.badge.clock",
                title: title,
                detail: "\(momentPhrase(event.assetCount)) · \(event.startDate.formatted(date: .abbreviated, time: .omitted))",
                coverIdentifier: event.coverIdentifier ?? event.assetIdentifiers.first,
                destination: .assets(title: title, identifiers: event.assetIdentifiers)
            )

        case .memory:
            guard let record = fetchMemory(key: item.reference, context: context) else {
                return KeptItem(symbol: "sparkles", title: "A memory",
                                detail: "No longer in your library", coverIdentifier: nil,
                                destination: nil)
            }
            return KeptItem(
                symbol: "sparkles",
                title: record.title,
                detail: record.subtitle ?? momentPhrase(record.assetCount),
                coverIdentifier: record.coverIdentifier ?? record.assetIdentifiers.first,
                destination: .memory(candidate(from: record))
            )

        case .day:
            guard let parts = isoDay(item.reference) else {
                // Written by a build that stored the day's *display title* — "7 August" — so
                // there is no date to reconstruct and no window to open. The stored text is
                // shown as it stands rather than being guessed at.
                return KeptItem(symbol: "calendar", title: item.reference, detail: "A day",
                                coverIdentifier: nil, destination: nil)
            }
            let window = TimeWindow.dayAcrossYears(month: parts.month, day: parts.day)
            return KeptItem(symbol: "calendar", title: window.title,
                            detail: "Every year", coverIdentifier: nil,
                            destination: .day(month: parts.month, day: parts.day))
        }
    }

    // MARK: Looking things up

    private static func fetchEvent(_ id: UUID, context: ModelContext) -> EventCluster? {
        var descriptor = FetchDescriptor<EventCluster>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchMemory(key: String, context: ModelContext) -> MemoryRecord? {
        var descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The stored row, put back into the shape `MemoryDetailView` opens.
    ///
    /// The score components are not stored on the record and are not wanted here: they decide
    /// whether a memory is worth *proposing* today, and this one was chosen by the user, which
    /// settles that question.
    private static func candidate(from record: MemoryRecord) -> MemoryCandidate {
        MemoryCandidate(id: record.key,
                        kind: record.kind,
                        title: record.title,
                        subtitle: record.subtitle,
                        referenceDate: record.referenceDate,
                        assetIdentifiers: record.assetIdentifiers,
                        coverIdentifier: record.coverIdentifier,
                        eventID: record.eventClusterID,
                        placeName: record.placeName,
                        components: ScoreComponents(),
                        score: record.score)
    }

    /// `2026-08-07`, which is what `CollectionRecord` documents a day reference to be.
    ///
    /// Parsed by hand rather than with a `DateFormatter`: this string is data, not display, so
    /// it must not be read through the reader's calendar or numbering system — an Arabic-Indic
    /// or Buddhist-calendar parse of a stored ISO day is a different day.
    private static func isoDay(_ reference: String) -> (month: Int, day: Int)? {
        let parts = reference.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        return (month, day)
    }

    private static func momentPhrase(_ count: Int) -> String {
        count == 1 ? "1 moment" : "\(count.formatted()) moments"
    }
}

/// A kept occasion or memory, opened: the photographs it holds, in the app's own grid.
private struct KeptAssetsScreen: View {
    let title: String
    let identifiers: [String]

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true

    var body: some View {
        AssetCollectionScreen(
            title: title,
            records: records,
            emptyTitle: "Nothing left here",
            emptyDetail: "The photographs this held are no longer in your library.",
            isLoading: isLoading
        )
        .task {
            await Task.yield()
            records = LibraryQuery.records(for: identifiers,
                                           context: app.container.mainContext)
            isLoading = false
        }
    }
}

/// A kept day, opened: that calendar day across every year in the library, which is what
/// keeping a day was meant to mean.
private struct KeptDayScreen: View {
    let month: Int
    let day: Int

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true

    private var window: TimeWindow { .dayAcrossYears(month: month, day: day) }

    var body: some View {
        AssetCollectionScreen(
            title: window.title,
            records: records,
            emptyTitle: "Nothing from this day",
            emptyDetail: "There are no photos in your library for this day, in any year.",
            isLoading: isLoading
        )
        .task { await load() }
    }

    /// Off the main actor, for the same reason `TimeWindowResultsView.load` is: a day across
    /// twenty years is twenty indexed reads plus a curation pass, and doing that on the main
    /// thread stops the push animation that is still running.
    private func load() async {
        let query = TimeWindowQuery(modelContainer: app.container)
        let identifiers = await query.flat(window: window,
                                           options: app.settings.curationOptions)
        records = LibraryQuery.records(for: identifiers, context: app.container.mainContext)
        isLoading = false
    }
}

/// Pick or create a collection for whatever is being kept.
struct AddToCollectionSheet: View {
    let items: [CollectionItem]
    let suggestedCover: String?
    /// Called with the collection's name once something is genuinely kept, so the caller can
    /// record the save then rather than when the sheet merely opened.
    var onSaved: (String) -> Void = { _ in }

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CollectionRecord.sortIndex) private var collections: [CollectionRecord]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Keep in") {
                    ForEach(collections) { collection in
                        Button {
                            add(to: collection)
                        } label: {
                            HStack {
                                Text(collection.name)
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: Space.s)
                                // Formatted, like every other count in the app, so the digits
                                // follow the reader rather than this file.
                                Text(collection.itemCount, format: .number)
                                    .foregroundStyle(Palette.textTertiary)
                                    .monospacedDigit()
                            }
                            .font(Typo.label)
                            .frame(minHeight: Hit.min)
                            .contentShape(.rect)
                        }
                        .accessibilityLabel("\(collection.name), \(itemPhrase(collection.itemCount))")
                    }
                }
                Section("New collection") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Create") { createAndAdd() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(minHeight: Hit.min)
                }
            }
            // The sheet is a form, so it stops at a measure on a regular-width window instead
            // of running a name and a number to opposite edges of an iPad.
            .readableMeasure()
            .navigationTitle("Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func add(to collection: CollectionRecord) {
        collection.items.append(contentsOf: items)
        collection.updatedAt = .now
        if collection.coverIdentifier == nil { collection.coverIdentifier = suggestedCover }
        app.container.mainContext.saveIfNeeded()
        Haptics.impact(.light)
        onSaved(collection.name)
        dismiss()
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let context = app.container.mainContext
        let collection = CollectionRecord(name: name)
        collection.sortIndex = collections.count
        context.insert(collection)
        add(to: collection)
    }
}
