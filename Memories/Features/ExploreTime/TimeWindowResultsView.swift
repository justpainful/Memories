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
    /// The results arrive all at once and replace everything on screen, which is the largest
    /// movement this sheet makes.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: CurationMode = .smart
    @State private var groups: [YearSlice] = []
    /// Identifiers rather than rows. The query runs on its own actor now and `AssetRecord`
    /// belongs to that actor's context, so what comes back has to be something the main actor
    /// may hold — and the grid asks Photos for the pictures by identifier regardless.
    @State private var flat: [String] = []
    /// What each identifier is and when it was taken, which is all a tile needs to be able to
    /// name itself out loud. Carried across from the query with the identifiers, because the
    /// rows it was read from cannot leave that actor.
    @State private var moments: [String: TileMoment] = [:]
    @State private var viewing: String?
    @State private var isLoading = true
    @State private var isSaving = false
    /// The width this sheet was actually given, so the grid's margins can answer a window
    /// rather than a phone.
    @State private var contentWidth: CGFloat = 0

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: Space.xs)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    // Scrollable, like the identical pair on the feed and in a memory: two
                    // chips at the accessibility sizes want more width than the screen has,
                    // and a fixed row answers that by truncating both labels to three letters.
                    ScrollView(.horizontal) {
                        GlassEffectContainer(spacing: 12) {
                            HStack(spacing: 10) {
                                GlassChip(title: "Smart", systemImage: "wand.and.sparkles",
                                          isSelected: mode == .smart) { setMode(.smart) }
                                GlassChip(title: "Pure", systemImage: "square.stack",
                                          isSelected: mode == .pure) { setMode(.pure) }
                            }
                            .padding(.horizontal, Space.gutter)
                            // Liquid Glass draws a little outside the view's own bounds, and
                            // without room for it the scroll view clips the capsules.
                            .padding(.vertical, 8)
                        }
                    }
                    .scrollIndicators(.hidden)

                    if isLoading {
                        QuietStatusView(title: "Looking through your library", symbol: "clock")
                    } else if allIdentifiers.isEmpty {
                        // The window's name as it is written, not lowercased into the middle of
                        // a sentence: "Every August" is a name, and "nothing from every august"
                        // is neither the name nor a sentence.
                        QuietStatusView(
                            title: "Nothing from \(window.title)",
                            detail: "There are no photos in your library for this stretch of time.",
                            symbol: "calendar.badge.exclamationmark"
                        )
                    } else if window.isThroughTheYears {
                        ForEach(groups) { slice in
                            VStack(alignment: .leading, spacing: Space.s) {
                                SectionHeader(overline: nil,
                                              title: slice.year.formatted(.number.grouping(.never)),
                                              subtitle: momentsText(slice.count))
                                    // Without the trait the year cannot be reached from the
                                    // headings rotor, which on a screen built to be read year
                                    // by year is the only way through it.
                                    .accessibilityAddTraits(.isHeader)
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
            .measuringWidth($contentWidth)
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
                    items: [CollectionItem(kind: .day, reference: dayReference)]
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
                // This is where Explore Time lands, and it was a wall of buttons with no
                // names: the year was in a heading somewhere above and every photograph in it
                // announced nothing at all.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(moments[identifier]?.spoken ?? "Photo")
            }
        }
        .padding(.horizontal, gridMargin)
    }

    /// Four points from the edge is a contact sheet on a phone and a bleed on anything wider,
    /// where every other surface in the app — including the chips directly above this grid —
    /// keeps a twenty-point gutter.
    private var gridMargin: CGFloat {
        contentWidth > 500 ? Space.gutter : Space.xs
    }

    private func momentsText(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "moment" : "moments")"
    }

    /// A day kept in a collection, written as a date rather than as the words this app happened
    /// to use for that day in the language the phone was in at the time.
    ///
    /// `window.title` used to go straight into the store, so a day kept in English was recorded
    /// as "August 12" and stayed "August 12" for good, and the same day kept again in another
    /// language became a second, unrelated row. `CollectionItem.reference` already says what it
    /// wants: an identifier, and for a day an ISO one.
    private var dayReference: String {
        guard case .dayAcrossYears(let month, let day) = window else { return window.title }
        // ISO 8601's recurring form — no year, because this window is that day in every year.
        return "--\(twoDigits(month))-\(twoDigits(day))"
    }

    /// Deliberately not `formatted`: this is a key, so it wants the same ASCII digits in every
    /// language rather than the reader's own numbering system.
    private func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
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
        let found = await query.results(window: window, options: options)

        // Switching Smart to Pure and back leaves two queries in flight, and the one that
        // finishes last is not necessarily the one the chips are showing.
        guard mode == requested else { return }

        // What arrives can be an entire year of photographs, and animating it means every tile
        // fading and sliding into place at once.
        if reduceMotion {
            apply(found)
        } else {
            withAnimation(.smooth(duration: 0.3)) { apply(found) }
        }
    }

    private func apply(_ found: TimeWindowResult) {
        groups = found.slices
        flat = found.flat
        moments = found.moments
        isLoading = false
    }
}

// MARK: - What a tile can say

/// The little a grid tile needs to know about a photograph in order to name itself.
///
/// It exists because the rows themselves cannot leave `TimeWindowQuery`'s context, and a
/// photograph announced as an unnamed button is the same as no photograph at all.
struct TileMoment: Sendable, Hashable {
    var date: Date
    var isVideo: Bool
    var isLivePhoto: Bool
    var duration: Double

    var spoken: String {
        var parts: [String] = []
        if isVideo {
            parts.append("Video")
            if duration > 0 {
                // Spoken units rather than "2:07", which is read out as two numbers.
                parts.append(Duration.seconds(Int(duration))
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
            }
        } else if isLivePhoto {
            parts.append("Live Photo")
        } else {
            parts.append("Photo")
        }
        parts.append(date.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: ", ")
    }
}

/// One screenful of an Explore Time window: the identifiers, however they are grouped, and
/// what each of them is.
struct TimeWindowResult: Sendable {
    var flat: [String] = []
    var slices: [YearSlice] = []
    var moments: [String: TileMoment] = [:]
}

// MARK: - Querying

/// The Explore Time query, on its own actor with its own context.
///
/// It exists so that the work never lands on the main thread; see `TimeWindowResultsView.load`
/// for what happened when it did. Nothing but identifiers, year slices and the handful of
/// facts a tile speaks aloud crosses back — `AssetRecord` belongs to this actor's context and
/// cannot be handed to a view.
@ModelActor
actor TimeWindowQuery {

    /// Everything one window's screenful needs, in a single crossing.
    ///
    /// One entry point rather than two, because the descriptions the grid reads out are taken
    /// from the same rows the identifiers came from. Asking for them separately afterwards
    /// would mean fetching every row a second time to learn what it already had in hand.
    func results(window: TimeWindow, options: CurationOptions) -> TimeWindowResult {
        var result = TimeWindowResult()

        if window.isThroughTheYears {
            let calendar = Calendar.current
            var slices: [YearSlice] = []
            for interval in window.intervals() {
                let found = Curator.curate(
                    LibraryQuery.assets(in: [interval], options: options, context: modelContext),
                    options: options
                )
                // A year that turns up empty is dropped rather than shown as a heading with
                // nothing underneath it.
                guard !found.isEmpty else { continue }
                describe(found, into: &result.moments)
                slices.append(YearSlice(
                    year: calendar.component(.year, from: interval.start),
                    assetIdentifiers: found.map(\.localIdentifier),
                    coverIdentifier: Curator.cover(for: found)?.localIdentifier
                ))
            }
            result.slices = slices.sorted { $0.year > $1.year }
            return result
        }

        let found: [AssetRecord]
        if case .surpriseMe = window {
            found = surprise(options: options)
        } else {
            found = Array(Curator.curate(
                LibraryQuery.assets(in: window.intervals(), options: options, context: modelContext),
                options: options
            ).reversed())
        }
        describe(found, into: &result.moments)
        result.flat = found.map(\.localIdentifier)
        return result
    }

    private func describe(_ records: [AssetRecord], into moments: inout [String: TileMoment]) {
        for record in records {
            moments[record.localIdentifier] = TileMoment(date: record.momentDate,
                                                         isVideo: record.isVideo,
                                                         isLivePhoto: record.isLivePhoto,
                                                         duration: record.duration)
        }
    }

    /// Not "any photo at all": the same rules the feed's smart random uses.
    private func surprise(options: CurationOptions) -> [AssetRecord] {
        let pool = LibraryQuery.allRecords(context: modelContext, limit: 800)
            .filter { LibraryQuery.passes($0, options: options) && $0.memoryScore > 0.5 }
        var generator = SeededGenerator(seed: UInt64(Date.now.timeIntervalSince1970) / 60)
        return Array(pool.shuffled(using: &generator).prefix(60))
    }
}
