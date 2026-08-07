import SwiftData
import SwiftUI

/// Where Explore Time lands.
///
/// A window that spans years is shown grouped by year rather than as one long run — the
/// point of jumping to "this week through the years" is to see the years side by side.
struct TimeWindowResultsView: View {
    let window: TimeWindow

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var mode: CurationMode = .smart
    @State private var groups: [YearSlice] = []
    /// Identifiers rather than rows. The query runs on its own actor now and `AssetRecord`
    /// belongs to that actor's context, so what comes back has to be something the main actor
    /// may hold — and the grid asks Photos for the pictures by identifier regardless.
    @State private var flat: [String] = []
    @State private var viewing: String?
    @State private var isLoading = true
    @State private var isSaving = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: Space.xs)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 10) {
                            GlassChip(title: "Smart", systemImage: "wand.and.sparkles",
                                      isSelected: mode == .smart) { setMode(.smart) }
                            GlassChip(title: "Pure", systemImage: "square.stack",
                                      isSelected: mode == .pure) { setMode(.pure) }
                            Spacer()
                        }
                    }
                    .padding(.horizontal, Space.gutter)

                    if isLoading {
                        QuietStatusView(title: "Looking through your library", symbol: "clock")
                    } else if allIdentifiers.isEmpty {
                        QuietStatusView(
                            title: "Nothing from \(window.title.lowercased())",
                            detail: "There are no photos in your library for this stretch of time.",
                            symbol: "calendar.badge.exclamationmark"
                        )
                    } else if window.isThroughTheYears {
                        ForEach(groups) { slice in
                            VStack(alignment: .leading, spacing: Space.s) {
                                SectionHeader(overline: nil,
                                              title: String(slice.year),
                                              subtitle: "\(slice.count) \(slice.count == 1 ? "moment" : "moments")")
                                grid(slice.assetIdentifiers)
                            }
                        }
                    } else {
                        grid(flat)
                    }
                }
                .padding(.top, Space.s)
                .padding(.bottom, Space.section)
            }
            .scrollIndicators(.hidden)
            .background(Palette.canvas)
            .navigationTitle(window.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if case .dayAcrossYears = window {
                    ToolbarItem(placement: .topBarLeading) {
                        // A whole day is one of the things a collection can hold, so the day
                        // view is where it has to be possible to keep one.
                        Button { isSaving = true } label: {
                            Image(systemName: "plus.rectangle.on.folder")
                        }
                        .disabled(allIdentifiers.isEmpty)
                        .accessibilityLabel("Keep this day")
                    }
                }
            }
            .sheet(isPresented: $isSaving) {
                AddToCollectionSheet(
                    items: [CollectionItem(kind: .day, reference: window.title)]
                        + allIdentifiers.map { CollectionItem(kind: .asset, reference: $0) },
                    suggestedCover: allIdentifiers.first
                )
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(item: Binding(
                get: { viewing.map(ViewerRequest.init(identifier:)) },
                set: { viewing = $0?.identifier }
            )) { request in
                PhotoViewerView(identifiers: allIdentifiers, startAt: request.identifier)
            }
        }
        .task {
            mode = app.settings.smartCuration ? .smart : .pure
            await load()
        }
    }

    private var allIdentifiers: [String] {
        window.isThroughTheYears ? groups.flatMap(\.assetIdentifiers) : flat
    }

    private func grid(_ identifiers: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: Space.xs) {
            ForEach(identifiers, id: \.self) { identifier in
                Button { viewing = identifier } label: {
                    PhotoImageView(identifier: identifier, targetSide: 240)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(.rect(cornerRadius: Radius.gridTile))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.xs)
    }

    private func setMode(_ newMode: CurationMode) {
        guard mode != newMode else { return }
        mode = newMode
        Haptics.selection()
        Task { await load() }
    }

    /// Fetch and curate this window, off the main actor.
    ///
    /// This used to be a synchronous run against `mainContext` called straight out of `.task`,
    /// and it is not a small one: "every August" is fifteen indexed reads plus a curation pass
    /// over everything they return. It therefore blocked the main thread at the single worst
    /// moment available to it — while this sheet was animating in and, behind it, the Explore
    /// panel was still folding back into the tab bar. Both stopped where they were until the
    /// query finished. A glass morph frozen half-way is not a subtle failure; it is a smear
    /// across the bottom of the screen, and it is very likely what "the nav bar sometimes
    /// sticks" describes. `isLoading` could not help either, being set and cleared inside one
    /// unbroken run of main-actor work, so the placeholder it drives never reached the screen.
    private func load() async {
        let requested = mode
        isLoading = true

        var options = app.settings.curationOptions
        options.mode = requested

        let query = TimeWindowQuery(modelContainer: app.container)
        var slices: [YearSlice] = []
        var run: [String] = []
        if window.isThroughTheYears {
            slices = await query.slices(window: window, options: options)
        } else {
            run = await query.flat(window: window, options: options)
        }

        // Switching Smart to Pure and back leaves two queries in flight, and the one that
        // finishes last is not necessarily the one the chips are showing.
        guard mode == requested else { return }

        withAnimation(.smooth(duration: 0.3)) {
            groups = slices
            flat = run
            isLoading = false
        }
    }
}

// MARK: - Querying

/// The Explore Time query, on its own actor with its own context.
///
/// It exists so that the work never lands on the main thread; see `TimeWindowResultsView.load`
/// for what happened when it did. Nothing but identifiers and year slices crosses back —
/// `AssetRecord` belongs to this actor's context and cannot be handed to a view.
@ModelActor
actor TimeWindowQuery {

    /// One flat run, newest first.
    func flat(window: TimeWindow, options: CurationOptions) -> [String] {
        if case .surpriseMe = window { return surprise(options: options) }

        let found = Curator.curate(
            LibraryQuery.assets(in: window.intervals(), options: options, context: modelContext),
            options: options
        )
        return found.reversed().map(\.localIdentifier)
    }

    /// One slice per year, newest year first. A year that turns up empty is dropped rather
    /// than shown as a heading with nothing underneath it.
    func slices(window: TimeWindow, options: CurationOptions) -> [YearSlice] {
        let calendar = Calendar.current
        return window.intervals()
            .compactMap { interval -> YearSlice? in
                let found = Curator.curate(
                    LibraryQuery.assets(in: [interval], options: options, context: modelContext),
                    options: options
                )
                guard !found.isEmpty else { return nil }
                return YearSlice(
                    year: calendar.component(.year, from: interval.start),
                    assetIdentifiers: found.map(\.localIdentifier),
                    coverIdentifier: Curator.cover(for: found)?.localIdentifier
                )
            }
            .sorted { $0.year > $1.year }
    }

    /// Not "any photo at all": the same rules the feed's smart random uses.
    private func surprise(options: CurationOptions) -> [String] {
        let pool = LibraryQuery.allRecords(context: modelContext, limit: 800)
            .filter { LibraryQuery.passes($0, options: options) && $0.memoryScore > 0.5 }
        var generator = SeededGenerator(seed: UInt64(Date.now.timeIntervalSince1970) / 60)
        return pool.shuffled(using: &generator).prefix(60).map(\.localIdentifier)
    }
}
