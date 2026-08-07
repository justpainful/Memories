import CoreLocation
import SwiftData
import SwiftUI

/// What is actually known about one photograph.
///
/// Deliberately no scores. The quality numbers exist to rank memories internally; putting
/// them in front of the user would turn their own photographs into a leaderboard.
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
                        Section {
                            row("Taken", record.creationDate.formatted(date: .complete, time: .shortened))
                            if let modified = record.modificationDate, modified != record.creationDate {
                                row("Edited", modified.formatted(date: .abbreviated, time: .shortened))
                            }
                        }

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

                        if record.hasLocation {
                            Section("Place") {
                                row("Where", placeName ?? "Looking up…")
                            }
                        }

                        Section {
                            if let clusterID = record.similarityClusterID,
                               let count = similarCount(clusterID), count > 1 {
                                row("Similar frames", "\(count)")
                                row("Best of its group", record.isBestInSimilarityCluster ? "Yes" : "No")
                            }
                            if record.eventClusterID != nil {
                                row("Part of an occasion", "Yes")
                            }
                        }

                        Section {
                            row("Stored on this iPhone", record.isLocallyAvailable ? "Yes" : "In iCloud only")
                            row("Uploaded by Memories", "Never")
                        } footer: {
                            Text("Memories analyzes photos on this device. Nothing about this photo has left your iPhone.")
                        }
                    }
                } else {
                    QuietStatusView(title: "This photo is no longer in your library",
                                    symbol: "questionmark.circle")
                }
            }
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

    private var record: AssetRecord? {
        LibraryQuery.records(for: [identifier], context: app.container.mainContext).first
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(value).foregroundStyle(Palette.textSecondary)
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
