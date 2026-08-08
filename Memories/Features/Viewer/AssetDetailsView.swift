import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// What is actually known about one photograph.
///
/// Deliberately no scores. The quality numbers exist to rank memories internally; putting
/// them in front of the user would turn their own photographs into a leaderboard.
///
/// This is the panel the viewer pulls up, so it opens with the thing worth knowing — when
/// the photograph actually happened — and lets everything mechanical sit below the fold.
/// Anything inferred rather than recorded is said to be inferred, in the row itself.
struct AssetDetailsView: View {
    let identifier: String

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss

    /// The row, read once when the panel opens rather than on every pass of this body.
    ///
    /// It used to be a computed property, which meant a synchronous fetch against
    /// `mainContext` every time SwiftUI evaluated the body — and this panel is a sheet the
    /// user drags between detents, so that is a database query per frame of a drag.
    @State private var record: AssetRecord?
    @State private var people: [PersonRecord] = []

    /// True while the pass that finds faces has not reached this photograph yet. Only then is
    /// "nobody has been recognised" an honest thing to say.
    @State private var isStillLookingForFaces = false
    @State private var hasLoaded = false

    @State private var placeName: String?
    /// The geocoder can simply not answer — offline, or a coordinate in the middle of an
    /// ocean. Without this the Where row sits on "Looking up…" for as long as the panel is
    /// open, which is a promise the app cannot keep.
    @State private var placeLookupFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let record {
                    List {
                        whenSection(record)
                        originSection(record)
                        if let coordinate = mapCoordinate(record) {
                            placeSection(coordinate)
                        }
                        peopleSection
                        aboutSection(record)
                        groupingSection(record)
                        privacySection(record)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                } else if hasLoaded {
                    QuietStatusView(title: "This photo is no longer in your library",
                                    symbol: "questionmark.circle")
                } else {
                    // Nothing at all until the fetch has answered. Announcing that a
                    // photograph has left the library for the frame it takes to read one row
                    // reads as a bug, not as loading.
                    Color.clear
                }
            }
            // A list of label/value pairs is read, not looked at, so on a wide window it stops
            // at a comfortable measure instead of putting a switch a foot from its own label.
            .readableMeasure()
            .background(Palette.canvas)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            load()
            await resolvePlace()
        }
    }

    // MARK: When

    /// `momentDate`, not `creationDate`. Photos stores the day a file entered the library,
    /// which for anything saved from another app is the day it was saved — so a clip from a
    /// holiday three years ago would otherwise read as if it happened last week.
    @ViewBuilder
    private func whenSection(_ record: AssetRecord) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(record.momentDate.formatted(date: .long, time: .omitted))
                    .font(Typo.dateHeadline)
                    .foregroundStyle(Palette.textPrimary)
                Text(record.momentDate.formatted(.dateTime.weekday(.wide).hour().minute()))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.vertical, Space.xs)

            if let modified = record.modificationDate, modified != record.creationDate {
                row("Edited", modified.formatted(date: .abbreviated, time: .shortened))
            }
        } footer: {
            if record.hasCorrectedDate {
                Text("""
                     Your library dates this \
                     \(record.creationDate.formatted(date: .abbreviated, time: .omitted)) — the day it \
                     was saved to \(DeviceName.thisDevice). The date above came from the file itself.
                     """)
            }
        }
    }

    // MARK: Where it came from

    @ViewBuilder
    private func originSection(_ record: AssetRecord) -> some View {
        if let source = record.source {
            Section {
                HStack(spacing: Space.m) {
                    Image(systemName: source.symbol)
                        .font(Typo.scaled(15))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(minWidth: 22)
                    Text(origin(source))
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typo.label)
                // One element carrying one sentence. Left as two, VoiceOver reads the symbol's
                // own name — "airplane" — before the line it is decorating.
                .accessibilityElement(children: .combine)

                if let filename = record.originalFilename {
                    row("File", filename)
                }
            } header: {
                Text("Where it came from")
            } footer: {
                Text("Read from the file’s name rather than recorded by Photos, so it can be wrong.")
            }
        }
    }

    // MARK: Place

    @ViewBuilder
    private func placeSection(_ coordinate: CLLocationCoordinate2D) -> some View {
        Section("Place") {
            // Interaction is switched off deliberately. This panel is something you drag, and
            // a live map inside it would swallow that drag the moment a finger landed on it.
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                            latitudinalMeters: 1_200,
                                                            longitudinalMeters: 1_200)),
                interactionModes: []) {
                Marker(placeName ?? "", coordinate: coordinate)
            }
            .frame(height: 156)
            .clipShape(.rect(cornerRadius: Radius.tile))
            .listRowInsets(EdgeInsets(top: Space.s, leading: Space.m,
                                      bottom: Space.s, trailing: Space.m))
            .accessibilityLabel(placeName ?? "Where this was taken")

            row("Where", placeText)
        }
    }

    /// A name, an admission that there is not going to be one, or the wait in between.
    private var placeText: String {
        if let placeName, !placeName.isEmpty { return placeName }
        return placeLookupFailed ? "No name for this spot" : "Looking up…"
    }

    // MARK: People

    /// Who the app has actually grouped in this photograph.
    ///
    /// This used to be a fixed sentence saying nobody had been recognised, printed over
    /// photographs whose faces the People screen had already grouped and named. A negative
    /// claim is the one thing a stub must never make, so the section is omitted entirely when
    /// there is nobody to show — except while the pass that finds faces is still running,
    /// which is the only moment "we have not looked yet" is true.
    @ViewBuilder
    private var peopleSection: some View {
        if !people.isEmpty {
            Section("People") {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Space.l) {
                        ForEach(people) { person in
                            NavigationLink {
                                PersonScreen(person: person)
                            } label: {
                                VStack(spacing: Space.s) {
                                    FaceThumbnail(person: person, side: 56)
                                    Text(person.displayName)
                                        .font(Typo.meta)
                                        .foregroundStyle(person.isNamed ? Palette.textPrimary
                                                                        : Palette.textTertiary)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.8)
                                        .multilineTextAlignment(.center)
                                }
                                // The face and the name are one person, and the whole tile is
                                // what a finger is aiming at.
                                .frame(minWidth: Hit.min, minHeight: Hit.min)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(person.displayName)
                            .accessibilityHint("Shows everything they appear in")
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                .scrollIndicators(.hidden)
            }
        } else if isStillLookingForFaces {
            Section("People") {
                Text("Still looking for faces in your library.")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The photograph itself

    private func aboutSection(_ record: AssetRecord) -> some View {
        Section {
            row("Kind", kind(record))
            row("Dimensions", dimensions(record))
            if record.isVideo {
                row("Duration", record.duration.shortDuration)
                if record.mediaSubtypes.contains(.videoHighFrameRate) {
                    row("Recorded", "Slo-mo")
                } else if record.mediaSubtypes.contains(.videoTimelapse) {
                    row("Recorded", "Time-lapse")
                }
            }
            if record.isFavoriteInPhotos {
                row("Favourite in Photos", "Yes")
            }
        }
    }

    /// Width then height, and it stays that way in every language.
    ///
    /// `×` is bidi-neutral, so a bare `"\(w) × \(h)"` next to Arabic labels takes the
    /// paragraph's direction and displays the two numbers the other way round — with nothing
    /// on screen to say it happened. The isolate marks pin the run left-to-right, and the
    /// numbers are formatted rather than interpolated so their digits follow the locale like
    /// every date above them.
    private func dimensions(_ record: AssetRecord) -> String {
        let width = record.pixelWidth.formatted(.number.grouping(.never))
        let height = record.pixelHeight.formatted(.number.grouping(.never))
        return "\u{2066}\(width) × \(height)\u{2069}"
    }

    @ViewBuilder
    private func groupingSection(_ record: AssetRecord) -> some View {
        let similar = record.similarityClusterID.flatMap(similarCount) ?? 0

        if similar > 1 || record.eventClusterID != nil {
            Section {
                if similar > 1 {
                    row("Similar frames", similar.formatted())
                    row("Best of its group", record.isBestInSimilarityCluster ? "Yes" : "No")
                }
                if record.eventClusterID != nil {
                    row("Part of an occasion", "Yes")
                }
            }
        }
    }

    /// The claim made here has to survive being checked, so it is worded against what the app
    /// actually does. The photograph never leaves the device. The Place section above it asks
    /// Apple's geocoder for the name of a coordinate, which does — and a panel that asserts
    /// otherwise two rows below a live lookup is a panel the user is right not to believe.
    private func privacySection(_ record: AssetRecord) -> some View {
        Section {
            row("Stored on \(DeviceName.thisDevice)", record.isLocallyAvailable ? "Yes" : "In iCloud only")
            row("Uploaded by Memories", "Never")
        } footer: {
            if record.hasLocation {
                Text("""
                     Memories analyzes photos on this device. No photo leaves your \(DeviceName.current). \
                     Naming the place above sends its coordinate — and only its coordinate — \
                     to Apple’s geocoder.
                     """)
            } else {
                Text("Memories analyzes photos on this device. Nothing about this photo has left your \(DeviceName.current).")
            }
        }
    }

    // MARK: Pieces

    /// A label and its value, laid out by the system rather than by hand.
    ///
    /// This was an `HStack` with a `Spacer` between the two, which has no answer at large
    /// type: "Stored on this iPhone" and "In iCloud only" simply fight for one row, the label
    /// wraps to four lines and the value is squeezed into a column one word wide.
    /// `LabeledContent` stacks the value under the label at accessibility sizes for free, and
    /// it is what `PrivacyView` already uses — so the app now says the same thing twice
    /// instead of contradicting itself.
    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .font(Typo.label)
    }

    private func kind(_ record: AssetRecord) -> String {
        if record.isScreenshot { return "Screenshot" }
        if record.isLivePhoto { return "Live Photo" }
        if record.isVideo { return "Video" }
        if record.isPanorama { return "Panorama" }
        return "Photo"
    }

    /// `SourcePlatform.title` is a noun, so "saved from" is added only where it reads as
    /// English — "Saved from WhatsApp", but "This iPhone" and "Screenshot" stand alone.
    private func origin(_ platform: SourcePlatform) -> String {
        switch platform {
        case .camera, .screenshot, .screenRecording, .airdrop, .download:
            return platform.title
        default:
            return "Saved from \(platform.title)"
        }
    }

    private func mapCoordinate(_ record: AssetRecord) -> CLLocationCoordinate2D? {
        guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func similarCount(_ clusterID: UUID) -> Int? {
        var descriptor = FetchDescriptor<SimilarityCluster>(predicate: #Predicate { $0.id == clusterID })
        descriptor.fetchLimit = 1
        return try? app.container.mainContext.fetch(descriptor).first?.memberCount
    }

    /// Everything this panel shows, read once.
    ///
    /// The people join is the same one `MemoryDetailView` does: the faces found in this
    /// photograph, the person each of them was grouped into, and whoever the user has not
    /// hidden. It is done in memory rather than as a predicate because a `Set` of ids is not
    /// something SwiftData can be asked about, and the number of people in a library is small.
    private func load() {
        let context = app.container.mainContext
        record = LibraryQuery.records(for: [identifier], context: context).first
        hasLoaded = true

        let target = identifier
        let faces = (try? context.fetch(
            FetchDescriptor<FaceRecord>(predicate: #Predicate { $0.assetIdentifier == target })
        )) ?? []
        let personIDs = Set(faces.compactMap(\.personID))

        if personIDs.isEmpty {
            people = []
        } else {
            let everyone = (try? context.fetch(FetchDescriptor<PersonRecord>())) ?? []
            people = everyone.filter { personIDs.contains($0.id) && !$0.isHidden }
        }

        // Faces come out of the same pass that judges quality, so that pass finishing is the
        // moment "we have not looked yet" stops being the honest answer.
        let progress = context.analysisState.stageProgress[AnalysisStage.quality.rawValue] ?? 0
        isStillLookingForFaces = app.coordinator.isRunning || progress < 1
    }

    /// Reverse geocoding runs against the coordinates already stored in the photo. It is the
    /// one place the app touches the network, it is Apple's geocoder, and it sends a
    /// coordinate — never a photo.
    ///
    /// It is also allowed to fail, and says so when it does. Offline, or over open water,
    /// there is no name to be had, and leaving the row on "Looking up…" forever is a worse
    /// answer than admitting there is not one.
    private func resolvePlace() async {
        guard let record, let latitude = record.latitude, let longitude = record.longitude else { return }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location),
              let placemark = placemarks.first else {
            placeLookupFailed = true
            return
        }
        let name = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .joined(separator: ", ")
        if name.isEmpty { placeLookupFailed = true } else { placeName = name }
    }
}

/// The whole occasion this photograph belongs to.
struct EventSheet: View {
    let identifier: String

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var records: [AssetRecord] = []
    @State private var title = "Occasion"
    @State private var subtitle: String?
    @State private var eventID: UUID?
    @State private var isSaving = false
    @State private var selection = PhotoSelection()
    /// The grid has to be told the difference between "still reading" and "there is nothing
    /// here", or every occasion opens by announcing that it is empty for the half second it
    /// takes to fetch it.
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let subtitle {
                        Text(subtitle)
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, Space.gutter)
                            .padding(.top, Space.s)
                    }
                    AssetGridView(records: records,
                                  emptyTitle: "This occasion is empty",
                                  emptySymbol: "calendar.badge.clock",
                                  isLoading: isLoading,
                                  selection: selection)
                }
                .padding(.bottom, Space.section)
            }
            // The bar belongs to the screen, not to the grid. Declared inside the grid it is
            // laid out after the last photograph, so reaching Love or Save meant scrolling to
            // the end of the occasion first.
            .selectionActionBar(selection)
            .background(Palette.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    // A collection can hold a whole occasion, not only the loose frames
                    // inside it — that is the difference between this and an album.
                    Button { isSaving = true } label: {
                        Image(systemName: "plus.rectangle.on.folder")
                            .frame(minWidth: Hit.min, minHeight: Hit.min)
                            .contentShape(.rect)
                    }
                    .disabled(eventID == nil)
                    .accessibilityLabel("Keep this occasion")
                }
            }
            .sheet(isPresented: $isSaving) {
                if let eventID {
                    AddToCollectionSheet(
                        items: [CollectionItem(kind: .event, reference: eventID.uuidString)]
                            + records.map { CollectionItem(kind: .asset, reference: $0.localIdentifier) },
                        suggestedCover: records.first?.localIdentifier
                    )
                    .presentationDetents([.medium, .large])
                    // Detents are a compact-width idea and are ignored on a wide window, where
                    // a sheet with nothing said about it lands as a fixed form of the system's
                    // choosing. This is a form, so it is asked to be one.
                    .presentationSizing(.form)
                }
            }
        }
        .task { load() }
    }

    private func load() {
        // Every exit from here has to clear the flag, including the ones that give up. Left
        // set on an early return the sheet sits on a blank grid rather than saying what
        // happened.
        defer { isLoading = false }

        let context = app.container.mainContext
        guard let record = LibraryQuery.records(for: [identifier], context: context).first,
              let eventID = record.eventClusterID else { return }
        self.eventID = eventID

        var descriptor = FetchDescriptor<EventCluster>(predicate: #Predicate { $0.id == eventID })
        descriptor.fetchLimit = 1
        guard let event = try? context.fetch(descriptor).first else { return }

        records = LibraryQuery.records(for: event.assetIdentifiers, context: context)
        title = event.placeName ?? event.startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        subtitle = "\(event.assetCount) moments · \(event.startDate.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// "Show all 5" — the frames that were collapsed into one best shot.
struct SimilarPhotosView: View {
    let identifier: String

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var members: [AssetRecord] = []
    @State private var viewing: String?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if members.count > 1 {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(members, id: \.localIdentifier) { record in
                            Button { viewing = record.localIdentifier } label: {
                                PhotoImageView(identifier: record.localIdentifier, targetSide: 240)
                                    .aspectRatio(1, contentMode: .fill)
                                    .overlay(alignment: .topLeading) {
                                        if record.isBestInSimilarityCluster {
                                            bestBadge.padding(5)
                                        }
                                    }
                                    // Clipped after the badge, not before it. The other way
                                    // round the badge is free to hang off the photograph it
                                    // belongs to and land on its neighbour.
                                    .clipShape(.rect(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(label(for: record))
                        }
                    }
                    // A contact sheet reads as dense on a phone and as a bleed on anything
                    // wider, where the tiles simply multiply. Capped and centred, the frames
                    // stay the size they are meant to be compared at.
                    .padding(.horizontal, horizontalSizeClass == .regular ? Space.gutter : Space.xs)
                    .padding(.vertical, Space.xs)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    QuietStatusView(title: "No near-identical frames",
                                    detail: "This shot does not repeat anywhere else in your library.",
                                    symbol: "square.stack.3d.down.right")
                }
            }
            .background(Palette.canvas)
            .navigationTitle("Similar photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fullScreenCover(item: Binding(
                get: { viewing.map(ViewerRequest.init(identifier:)) },
                set: { viewing = $0?.identifier }
            )) { request in
                PhotoViewerView(identifiers: members.map(\.localIdentifier), startAt: request.identifier)
            }
        }
        .task { load() }
    }

    /// The marker that says which of several near-identical frames the app picked.
    ///
    /// It was nine-point white on the system blue: two points under the smallest label
    /// anywhere else in the app, at roughly 3.6:1 against its own capsule, which is below the
    /// ratio text this size needs. It now sits on `label` — the highest-contrast fill iOS
    /// has — at the size the rest of the app's overlines use, and it carries a star, so it
    /// still reads as "chosen" in greyscale or to someone who cannot separate the blue.
    private var bestBadge: some View {
        Label("Best", systemImage: "star.fill")
            .font(Typo.overline)
            .textCase(.uppercase)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Palette.canvas)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .background(Palette.textPrimary, in: .capsule)
            // A badge inside a 108-point tile is furniture: it cannot grow with the tile,
            // because the tile is sized by how many photographs fit across.
            .chromeTypeSize()
    }

    private func label(for record: AssetRecord) -> String {
        let date = record.momentDate.formatted(date: .abbreviated, time: .omitted)
        let kind = record.isVideo ? "Video" : "Photo"
        return record.isBestInSimilarityCluster
            ? "\(kind), \(date), best of this group"
            : "\(kind), \(date)"
    }

    private func load() {
        let context = app.container.mainContext
        guard let record = LibraryQuery.records(for: [identifier], context: context).first,
              let clusterID = record.similarityClusterID else {
            members = []
            return
        }
        var descriptor = FetchDescriptor<SimilarityCluster>(predicate: #Predicate { $0.id == clusterID })
        descriptor.fetchLimit = 1
        guard let cluster = try? context.fetch(descriptor).first else { return }
        members = LibraryQuery.records(for: cluster.memberIdentifiers, context: context)
    }
}
