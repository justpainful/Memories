import SwiftData
import SwiftUI
import UIKit

/// One memory, opened. A calm grid of what it contains, with the Smart/Pure switch right
/// where the decision matters.
struct MemoryDetailView: View {
    let candidate: MemoryCandidate

    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    /// Two settings this screen has to answer. The mode switch replaces the whole grid, and the
    /// tap on a tile blows a thumbnail up to fill the screen — the two largest movements here.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Ties a tile to the photograph it opens, so the thumbnail grows into the full screen and
    /// shrinks back into itself instead of the viewer sliding up out of the bottom edge.
    @Namespace private var opening

    /// The face and its caption grow together. A 64-point circle under a 40-point name reads as
    /// a caption that has escaped its picture.
    @ScaledMetric(relativeTo: .footnote) private var faceSide: CGFloat = 64
    @ScaledMetric(relativeTo: .footnote) private var personCellWidth: CGFloat = 76
    /// The icon column in the details card, and the hairline inset derived from it below.
    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 20

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

                // The pair is scrollable for the same reason the feed's filter row is. Two
                // chips at 16 points are a third of the width; at the accessibility sizes they
                // need more than the screen has, and a fixed `HStack` answers that by squeezing
                // them until the labels read "Sma…" and "Pur…" — which is the whole decision
                // this screen exists to offer, rendered illegible.
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 10) {
                            GlassChip(title: "Smart", systemImage: "wand.and.sparkles",
                                      isSelected: mode == .smart) { setMode(.smart) }
                            GlassChip(title: "Pure", systemImage: "square.stack",
                                      isSelected: mode == .pure) { setMode(.pure) }
                        }
                        .padding(.horizontal, Space.gutter)
                        // Liquid Glass renders slightly outside the view's own bounds; without
                        // room for it the scroll view clips the top and bottom off the capsules.
                        .padding(.vertical, 8)
                    }
                }
                .scrollIndicators(.hidden)

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
                        Label("Show all \(candidate.assetCount.formatted(.number))",
                              systemImage: "square.stack.3d.down.right")
                            .font(Typo.control)
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity, minHeight: Hit.min, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.gutter)
                }

                if !people.isEmpty { peopleStrip }
                if !records.isEmpty { details }
            }
            .padding(.top, Space.s)
            // The floating bar's measured height, not the number it happened to be on one
            // phone at the default text size.
            .padding(.bottom, bottomBarInset)
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
                // Opening a photograph expands the tapped thumbnail to fill the screen, which
                // is the largest movement on this screen by some distance. Reduce Motion asks
                // for it not to happen, so the modifier is applied conditionally rather than
                // trusted to substitute something quieter on its own.
                .modifier(ZoomIfAllowed(sourceID: request.identifier,
                                        namespace: opening,
                                        enabled: !reduceMotion))
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
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .glassPanel(cornerRadius: 20)
                    // 150 was 132 plus an eyeballed breath of air, so it carried every problem
                    // the 132 had and added one of its own. The toast has to clear the floating
                    // bar, and the bar knows how tall it is.
                    .padding(.bottom, bottomBarInset + Space.l)
                    .padding(.horizontal, Space.gutter)
                    .transition(reduceMotion ? .opacity
                                             : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: note)
        .onChange(of: note) { _, value in
            guard let value else { return }
            // The toast is the only confirmation that the save or the thumbs-down landed, and
            // it says so for a second and a half in a corner of the screen. Without this a
            // VoiceOver reader is told nothing at all.
            AccessibilityNotification.Announcement(value).post()
            // A second and a half is about as long as the sentence takes to be read out, so
            // under VoiceOver the caption is gone by the time the reader turns to look for it.
            let linger: Duration = UIAccessibility.isVoiceOverRunning ? .seconds(5) : .seconds(1.6)
            Task {
                try? await Task.sleep(for: linger)
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
            // "Full width" was written against a phone. A lone portrait frame across a
            // landscape iPad is a picture a screen and a quarter tall, and the memory's people
            // and details end up below two screenfuls of one photograph. The cap only bites on
            // a container wider than a large phone.
            .readableMeasure(640)
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
        // A tile is a photograph, sometimes a duration badge and sometimes a heart, and none of
        // those say anything on their own. Left alone, opening a memory — the app's central
        // act — hands a blind reader a run of buttons called "2:07", "heart fill", and mostly
        // nothing at all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.describe(record))
    }

    /// What a tile is, when it was taken and whether it is loved: the three things a sighted
    /// reader takes from looking at one.
    private static func describe(_ record: AssetRecord) -> String {
        var parts: [String] = []
        if record.isVideo {
            parts.append("Video")
            if record.duration > 0 {
                // Spoken units rather than "2:07", which VoiceOver reads as two numbers.
                parts.append(Duration.seconds(Int(record.duration))
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
            }
        } else if record.isLivePhoto {
            parts.append("Live Photo")
        } else {
            parts.append("Photo")
        }
        parts.append(record.momentDate.formatted(date: .abbreviated, time: .omitted))
        if record.isLoved { parts.append("Loved") }
        return parts.joined(separator: ", ")
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
                    // Fixed by the corner it sits in rather than by the type around it, so it
                    // uses the glyph size that does not scale. The state it marks is carried in
                    // the tile's accessibility label instead.
                    Image(systemName: "heart.fill")
                        .font(Typo.glyph(12, .regular))
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
                                FaceThumbnail(person: person, side: faceSide)
                                // Names are free text the user typed, so they are unbounded.
                                // Clipped to one line in a frozen 76-point box, "Alexandra
                                // Whitfield" was already an ellipsis at the default size and
                                // two characters at the accessibility ones — a row of identical
                                // circles captioned "Al…", which is the strip's whole purpose
                                // undone. It gets a second line and a little shrinking first.
                                Text(person.displayName)
                                    .font(Typo.meta)
                                    .foregroundStyle(person.isNamed ? Palette.textPrimary
                                                                    : Palette.textTertiary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.75)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: personCellWidth)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(person.displayName)
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

    /// Inset to where the text starts, derived from the icon column rather than written as 52.
    /// The literal was the column plus both paddings measured once; when the column grows with
    /// the type, a frozen inset leaves the rule starting under the middle of the next symbol.
    private var hairline: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, iconColumn + Space.l * 2)
    }

    private func detailRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Space.l) {
            Image(systemName: symbol)
                .font(Typo.scaled(16, .medium))
                .foregroundStyle(Palette.accent)
                // A frame gives a view its size, not a clip. A 16-point symbol at an
                // accessibility size is fifty points wide, and in a frozen 20-point slot the
                // overhang lands straight on the first word beside it.
                .frame(width: iconColumn)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: Hit.min)
        // The clock, the pin and the photo glyph are decoration for the sentence beside them,
        // and read aloud they are three SF Symbol names in front of it.
        .accessibilityElement(children: .combine)
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
        if photos > 0 {
            parts.append("\(photos.formatted(.number)) \(photos == 1 ? "photo" : "photos")")
        }
        if videos > 0 {
            parts.append("\(videos.formatted(.number)) \(videos == 1 ? "video" : "videos")")
        }
        // Each count fenced off from the other: the middle dot is bidi-neutral and takes its
        // direction from whatever surrounds it, so two runs of digits either side of one can
        // swap places. The isolates say where each run begins and ends.
        return parts.map { "\u{2068}\($0)\u{2069}" }.joined(separator: " · ")
    }

    private var hiddenByCuration: Int {
        max(0, candidate.assetCount - records.count)
    }

    private func setMode(_ newMode: CurationMode) {
        guard mode != newMode else { return }
        mode = newMode
        Haptics.selection()
        // `reload()` replaces the whole set, so animating it moves every tile on screen at
        // once — on a large memory, dozens of photographs sliding into new positions. The
        // haptic above still marks the switch, so nothing is lost by letting it happen at once.
        if reduceMotion {
            reload()
        } else {
            withAnimation(.smooth(duration: 0.3)) { reload() }
        }
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

/// The zoom transition, applied only when the reader has not asked for less movement.
///
/// A modifier rather than an `if` around the whole presented view, because the two branches
/// would otherwise be different views as far as SwiftUI is concerned and the viewer would be
/// rebuilt from scratch whenever the setting changed.
private struct ZoomIfAllowed: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}
