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
    @State private var placeName: String?

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
                } else {
                    QuietStatusView(title: "This photo is no longer in your library",
                                    symbol: "questionmark.circle")
                }
            }
            .background(Palette.canvas)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await resolvePlace() }
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
                     was saved to this iPhone. The date above came from the file itself.
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
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 22)
                    Text(origin(source))
                        .foregroundStyle(Palette.textPrimary)
                }
                .font(Typo.label)

                if let filename = record.originalFilename {
                    row("File", filename)
                }
            } header: {
                Text("Where it came from")
            } footer: {
                Text("Read from the file's name rather than recorded by Photos, so it can be wrong.")
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

            row("Where", placeName ?? "Looking up…")
        }
    }

    // MARK: People

    /// Deliberately empty. Another agent owns the face and person records that will fill this
    /// in; naming those types while they are still being written would only break the build.
    private var peopleSection: some View {
        Section("People") {
            Text("No one has been recognised in this photo yet.")
                .font(Typo.meta)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: The photograph itself

    private func aboutSection(_ record: AssetRecord) -> some View {
        Section {
            row("Kind", kind(record))
            row("Dimensions", "\(record.pixelWidth) × \(record.pixelHeight)")
            if record.isVideo {
                row("Duration", record.duration.shortDuration)
            }
            if record.isFavoriteInPhotos {
                row("Favourite in Photos", "Yes")
            }
        }
    }

    @ViewBuilder
    private func groupingSection(_ record: AssetRecord) -> some View {
        let similar = record.similarityClusterID.flatMap(similarCount) ?? 0

        if similar > 1 || record.eventClusterID != nil {
            Section {
                if similar > 1 {
                    row("Similar frames", "\(similar)")
                    row("Best of its group", record.isBestInSimilarityCluster ? "Yes" : "No")
                }
                if record.eventClusterID != nil {
                    row("Part of an occasion", "Yes")
                }
            }
        }
    }

    private func privacySection(_ record: AssetRecord) -> some View {
        Section {
            row("Stored on this iPhone", record.isLocallyAvailable ? "Yes" : "In iCloud only")
            row("Uploaded by Memories", "Never")
        } footer: {
            Text("Memories analyzes photos on this device. Nothing about this photo has left your iPhone.")
        }
    }

    // MARK: Pieces

    private var record: AssetRecord? {
        LibraryQuery.records(for: [identifier], context: app.container.mainContext).first
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.textPrimary)
            Spacer()
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

    /// Reverse geocoding runs against the coordinates already stored in the photo. It is the
    /// one place the app touches the network, it is Apple's geocoder, and it sends a
    /// coordinate — never a photo.
    private func resolvePlace() async {
        guard let record, let latitude = record.latitude, let longitude = record.longitude else { return }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return }
        placeName = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .joined(separator: ", ")
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
                                  emptySymbol: "calendar.badge.clock")
                }
                .padding(.bottom, Space.section)
            }
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
                }
            }
        }
        .task { load() }
    }

    private func load() {
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
                                    .clipShape(.rect(cornerRadius: 6))
                                    .overlay(alignment: .topLeading) {
                                        if record.isBestInSimilarityCluster {
                                            Text("BEST")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Palette.accent, in: .capsule)
                                                .padding(5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
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
