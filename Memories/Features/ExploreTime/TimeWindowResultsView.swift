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
    @State private var flat: [AssetRecord] = []
    @State private var viewing: String?
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

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
                        grid(flat.map(\.localIdentifier))
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
            load()
        }
    }

    private var allIdentifiers: [String] {
        window.isThroughTheYears ? groups.flatMap(\.assetIdentifiers) : flat.map(\.localIdentifier)
    }

    private func grid(_ identifiers: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(identifiers, id: \.self) { identifier in
                Button { viewing = identifier } label: {
                    PhotoImageView(identifier: identifier, targetSide: 240)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    private func setMode(_ newMode: CurationMode) {
        guard mode != newMode else { return }
        mode = newMode
        Haptics.selection()
        withAnimation(.smooth(duration: 0.3)) { load() }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        var options = app.settings.curationOptions
        options.mode = mode
        let context = app.container.mainContext
        let calendar = Calendar.current

        if case .surpriseMe = window {
            // Not "any photo at all": the same rules the feed's smart random uses.
            let pool = LibraryQuery.allRecords(context: context, limit: 800)
                .filter { LibraryQuery.passes($0, options: options) && $0.memoryScore > 0.5 }
            var generator = SeededGenerator(seed: UInt64(Date.now.timeIntervalSince1970) / 60)
            flat = Array(pool.shuffled(using: &generator).prefix(60))
            groups = []
            return
        }

        let intervals = window.intervals()
        if window.isThroughTheYears {
            groups = intervals.compactMap { interval -> YearSlice? in
                let found = Curator.curate(
                    LibraryQuery.assets(in: [interval], options: options, context: context),
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
            flat = []
        } else {
            flat = Curator.curate(
                LibraryQuery.assets(in: intervals, options: options, context: context),
                options: options
            ).reversed()
            groups = []
        }
    }
}
