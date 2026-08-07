import SwiftData
import SwiftUI

/// One memory, opened. A calm grid of what it contains, with the Smart/Pure switch right
/// where the decision matters.
struct MemoryDetailView: View {
    let candidate: MemoryCandidate

    @Environment(\.app) private var app
    /// Ties a tile to the photograph it opens, so the thumbnail grows into the full screen and
    /// shrinks back into itself instead of the viewer sliding up out of the bottom edge.
    @Namespace private var opening
    @State private var mode: CurationMode = .smart
    @State private var records: [AssetRecord] = []
    @State private var people: [PersonRecord] = []
    @State private var viewerStart: String?
    @State private var isSaving = false
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header

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

                if records.isEmpty {
                    QuietStatusView(title: "Nothing left in this memory",
                                    detail: "Everything here has been hidden from Memories.",
                                    symbol: "eye.slash")
                } else {
                    photographs
                }

                if mode == .smart, hiddenByCuration > 0 {
                    Button {
                        setMode(.pure)
                    } label: {
                        Label("Show all \(candidate.assetCount)", systemImage: "square.stack.3d.down.right")
                            .font(Typo.control)
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.gutter)
                }

                if !people.isEmpty { peopleStrip }
                if !records.isEmpty { details }
            }
            .padding(.top, Space.s)
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle(candidate.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // The save is recorded when the collection is actually chosen, not when
                    // the sheet opens — cancelling is not saving.
                    Button("Save to a collection", systemImage: "plus.rectangle.on.folder") {
                        isSaving = true
                    }
                    Button("Show me fewer like this", systemImage: "hand.thumbsdown") {
                        app.feedback.recordDismissed(candidate)
                        note = "This kind will show up less often"
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .fullScreenCover(item: Binding(
            get: { viewerStart.map(ViewerRequest.init(identifier:)) },
            set: { viewerStart = $0?.identifier }
        )) { request in
            PhotoViewerView(identifiers: records.map(\.localIdentifier),
                            startAt: request.identifier)
                .navigationTransition(.zoom(sourceID: request.identifier, in: opening))
        }
        .sheet(isPresented: $isSaving) {
            // A whole memory is kept as a memory, not exploded into loose files, plus its
            // frames so the collection can still be browsed as pictures.
            AddToCollectionSheet(
                items: [CollectionItem(kind: .memory, reference: candidate.id)]
                    + records.map { CollectionItem(kind: .asset, reference: $0.localIdentifier) },
                suggestedCover: candidate.coverIdentifier
            ) { name in
                app.feedback.recordSaved(candidate)
                note = "Kept in \(name)"
            }
            .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .bottom) {
            if let note {
                Text(note)
                    .font(Typo.control)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .glassPanel(cornerRadius: 20)
                    .padding(.bottom, 150)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.25), value: note)
        .onChange(of: note) { _, value in
            guard value != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                note = nil
            }
        }
        .task {
            mode = app.settings.smartCuration ? .smart : .pure
            reload()
            loadPeople()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(candidate.referenceDate, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .overlineStyle()
            if let subtitle = candidate.subtitle {
                Text(subtitle)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
    }

    // MARK: The photographs

    /// A short memory gets larger photographs rather than the same small tiles with a screen
    /// of white underneath them.
    ///
    /// The screen used to draw one fixed grid at roughly three across whatever it held, so a
    /// memory of three frames came out as a single band of thumbnails below the title and
    /// eleven hundred points of nothing beneath it — which reads as a screen that failed to
    /// load, not as a spacious one. Photos answers the same situation by making the pictures
    /// bigger, and the sizes below are chosen so that any memory fills at least a screenful:
    /// one frame is a full-width portrait, two are full-width squares, three to six run two
    /// across, and only once there are enough to fill the page on their own does the ordinary
    /// grid take over.
    @ViewBuilder
    private var photographs: some View {
        if records.count > 6 {
            // Enough frames to fill the page by themselves, so the density is the user's —
            // the same pinch, the same remembered choice, as every other grid in the app.
            PhotoGrid {
                ForEach(records, id: \.localIdentifier) { record in
                    openable(record) { tile(record, aspect: 1, cornerRadius: 6) }
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s),
                                     count: featureColumns),
                      spacing: Space.s) {
                ForEach(records, id: \.localIdentifier) { record in
                    openable(record) {
                        tile(record, aspect: featureAspect, cornerRadius: featureRadius)
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
        }
    }

    /// One or two frames run the full width; three to six pair up. Either way a memory now
    /// reaches the bottom of the screen with photographs rather than with white.
    private var featureColumns: Int { records.count > 2 ? 2 : 1 }

    /// A lone photograph is drawn as a portrait card, the shape the feed already opens on.
    private var featureAspect: CGFloat { records.count == 1 ? 0.8 : 1 }

    private var featureRadius: CGFloat { records.count > 2 ? Radius.tile : Radius.card }

    private func openable<Content: View>(_ record: AssetRecord,
                                         @ViewBuilder content: () -> Content) -> some View {
        Button { viewerStart = record.localIdentifier } label: {
            content()
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: record.localIdentifier, in: opening)
    }

    private func tile(_ record: AssetRecord, aspect: CGFloat, cornerRadius: CGFloat) -> some View {
        // A larger tile deserves a larger request; asking for a 240-point thumbnail and
        // stretching it across the screen is how a hero frame comes out soft.
        PhotoImageView(identifier: record.localIdentifier,
                       targetSide: aspect < 1 ? 900 : 600)
            .aspectRatio(aspect, contentMode: .fill)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay(alignment: .bottomLeading) {
                if record.isVideo || record.isLivePhoto {
                    MediaBadge(record: record).padding(Space.s)
                }
            }
            .overlay(alignment: .topTrailing) {
                if record.isLoved {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(Space.s)
                }
            }
    }

    // MARK: What else this memory knows

    /// The faces the app already grouped, filtered to the ones actually in this memory.
    private var peopleStrip: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("People").overlineStyle().padding(.horizontal, Space.gutter)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Space.l) {
                    ForEach(people) { person in
                        NavigationLink {
                            PersonScreen(person: person)
                        } label: {
                            VStack(spacing: Space.s) {
                                FaceThumbnail(person: person, side: 64)
                                Text(person.displayName)
                                    .font(Typo.meta)
                                    .foregroundStyle(person.isNamed ? Palette.textPrimary
                                                                    : Palette.textTertiary)
                                    .lineLimit(1)
                            }
                            .frame(width: 76)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Space.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// When, where and what — three things the app has already worked out and was throwing
    /// away. On a long memory they are a footnote; on a short one they are the rest of the page.
    private var details: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Details").overlineStyle().padding(.horizontal, Space.gutter)

            VStack(spacing: 0) {
                detailRow("clock", spanText)
                if let place = candidate.placeName {
                    hairline
                    detailRow("mappin.and.ellipse", place)
                }
                hairline
                detailRow("photo.on.rectangle.angled", makeupText)
            }
            // The sunk fill rather than the grouped surface: this card sits on
            // `systemBackground`, and `secondarySystemGroupedBackground` is white on white
            // there — a card that only exists in the dark.
            .background(Palette.surfaceSunk, in: .rect(cornerRadius: Radius.card))
            .padding(.horizontal, Space.gutter)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, 52)
    }

    private func detailRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 20)
            Text(text)
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    /// One day, or the two ends of it. The interval style collapses whatever the ends share.
    private var spanText: String {
        let dates = records.map(\.momentDate)
        guard let first = dates.min(), let last = dates.max() else {
            return candidate.referenceDate.formatted(date: .abbreviated, time: .omitted)
        }
        guard !Calendar.current.isDate(first, inSameDayAs: last) else {
            return first.formatted(date: .long, time: .omitted)
        }
        return (first..<last).formatted(date: .abbreviated, time: .omitted)
    }

    private var makeupText: String {
        let videos = records.filter { $0.isVideo }.count
        let photos = records.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) \(photos == 1 ? "photo" : "photos")") }
        if videos > 0 { parts.append("\(videos) \(videos == 1 ? "video" : "videos")") }
        return parts.joined(separator: " · ")
    }

    private var hiddenByCuration: Int {
        max(0, candidate.assetCount - records.count)
    }

    private func setMode(_ newMode: CurationMode) {
        guard mode != newMode else { return }
        mode = newMode
        Haptics.selection()
        withAnimation(.smooth(duration: 0.3)) { reload() }
    }

    private func reload() {
        var options = app.settings.curationOptions
        options.mode = mode
        // A memory the user opened deliberately shows what it contains, including
        // screenshots if that is what the occasion was.
        options.includeScreenshots = true

        let all = LibraryQuery.records(for: candidate.assetIdentifiers,
                                       context: app.container.mainContext)
            .filter { LibraryQuery.passes($0, options: options) }
        records = Curator.curate(all, options: options)
    }

    /// Whoever the app already grouped and who is actually in this memory, the person who
    /// turns up most first. Read against the memory's whole set rather than the curated one,
    /// so switching to Smart does not quietly drop somebody out of the row.
    private func loadPeople() {
        let inMemory = Set(candidate.assetIdentifiers)
        let descriptor = FetchDescriptor<PersonRecord>()
        let everyone = (try? app.container.mainContext.fetch(descriptor)) ?? []

        var appearances: [(person: PersonRecord, count: Int)] = []
        for person in everyone where !person.isHidden {
            let shared = person.assetIdentifiers.filter { inMemory.contains($0) }.count
            if shared > 0 { appearances.append((person, shared)) }
        }
        appearances.sort { $0.count > $1.count }
        people = appearances.prefix(12).map { $0.person }
    }
}

/// `fullScreenCover(item:)` needs an Identifiable; a bare String is not one.
struct ViewerRequest: Identifiable, Hashable {
    let identifier: String
    var id: String { identifier }
}
