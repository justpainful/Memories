import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// One place in one year, gathered from every occasion the app recorded there.
///
/// The rows under the map are the second way into a place, for when you remember the year
/// but not where the pin sits — so they carry the frames themselves, not just a tally.
private struct PlaceYear: Identifiable {
    let place: String
    let year: Int
    let assetIdentifiers: [String]

    var id: String { "\(place)·\(year)" }
    var count: Int { assetIdentifiers.count }
}

/// One place, with each of its years under it — the shape the list below the map is drawn in.
private struct PlaceGroup: Identifiable {
    let name: String
    let years: [PlaceYear]

    var id: String { name }
}

/// Where your photographs were taken, from the coordinates your camera already saved.
///
/// Not a Google Photos clone: the map is a way in, and what it leads to is the same thing
/// the rest of the app deals in — years, occasions and memories from that place.
struct PlacesView: View {
    @Environment(\.app) private var app

    @State private var events: [EventCluster] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: EventCluster?
    @State private var openYear: PlaceYear?
    /// Grouped once per load rather than once per redraw. Built in `body` it re-ran the whole
    /// group-and-sort every time the list scrolled a row in or a place name arrived from the
    /// geocoder, which on a library with a few hundred occasions is work done for nothing.
    @State private var groupedByPlace: [PlaceGroup] = []

    var body: some View {
        Group {
            if events.isEmpty {
                QuietStatusView(
                    title: "No places yet",
                    detail: "Photos need location saved by your camera for them to appear here.",
                    symbol: "mappin.slash"
                )
            } else {
                VStack(spacing: 0) {
                    Map(position: $camera) {
                        ForEach(events) { event in
                            if let latitude = event.latitude, let longitude = event.longitude {
                                Annotation(
                                    event.placeName ?? "",
                                    coordinate: CLLocationCoordinate2D(latitude: latitude,
                                                                       longitude: longitude)
                                ) {
                                    Button { selection = event } label: {
                                        if let cover = event.coverIdentifier {
                                            PhotoThumbnail(identifier: cover, side: 44, radius: 10)
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .strokeBorder(.white, lineWidth: 2)
                                                }
                                                .shadow(radius: 3)
                                        } else {
                                            // A pin drawn at label size is a 17-point target on
                                            // a map you are already fighting for a finger's
                                            // worth of space on.
                                            Image(systemName: "mappin.circle.fill")
                                                .font(.system(size: 26))
                                                .foregroundStyle(Palette.accent, .white)
                                                .frame(width: 44, height: 44)
                                                .contentShape(.circle)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(event.placeName ?? "An occasion")
                                }
                            }
                        }
                    }
                    .frame(height: 280)

                    List {
                        ForEach(groupedByPlace) { group in
                            Section(group.name) {
                                ForEach(group.years) { entry in
                                    Button { openYear = entry } label: {
                                        HStack {
                                            Text(String(entry.year))
                                                .font(Typo.label)
                                                .foregroundStyle(Palette.textPrimary)
                                            Spacer()
                                            Text("\(entry.count)")
                                                .font(Typo.meta)
                                                .foregroundStyle(Palette.textTertiary)
                                                .monospacedDigit()
                                        }
                                        .contentShape(.rect)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.bottom, 132, for: .scrollContent)
                }
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selection) { event in
            EventPlaceSheet(event: event)
        }
        .sheet(item: $openYear) { entry in
            PlaceYearSheet(entry: entry)
        }
        .task { await load() }
    }

    private func regroup() {
        let calendar = Calendar.current
        let named = events.filter { $0.placeName != nil }
        let byPlace = Dictionary(grouping: named) { $0.placeName ?? "" }

        groupedByPlace = byPlace.map { name, group in
            let byYear = Dictionary(grouping: group) { calendar.component(.year, from: $0.startDate) }
            let years = byYear
                .map { year, occasions in
                    PlaceYear(place: name, year: year,
                              assetIdentifiers: occasions.flatMap(\.assetIdentifiers))
                }
                .sorted { $0.year > $1.year }
            return PlaceGroup(name: name, years: years)
        }
        .sorted { lhs, rhs in
            lhs.years.reduce(0) { $0 + $1.count } > rhs.years.reduce(0) { $0 + $1.count }
        }
    }

    private func load() async {
        let context = app.container.mainContext
        let descriptor = FetchDescriptor<EventCluster>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        events = all.filter { $0.latitude != nil }
        regroup()
        await nameUnnamedPlaces()
    }

    /// Resolve place names lazily and store them, so the geocoder is asked once per place
    /// rather than every time this screen opens. Coordinates go out; photos never do.
    private func nameUnnamedPlaces() async {
        let geocoder = CLGeocoder()
        let context = app.container.mainContext

        for event in events.prefix(24) where event.placeName == nil {
            guard let latitude = event.latitude, let longitude = event.longitude else { continue }
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { continue }

            event.placeName = placemark.locality
                ?? placemark.subAdministrativeArea
                ?? placemark.administrativeArea
                ?? placemark.country
            context.saveIfNeeded()
            // A place that has just been named belongs in the list under the map now, not on
            // the next visit.
            regroup()
            try? await Task.sleep(for: .milliseconds(250))   // stay well inside rate limits
        }
    }
}

/// One occasion, opened from its pin on the map.
private struct EventPlaceSheet: View {
    let event: EventCluster

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true
    @State private var selection = PhotoSelection()

    var body: some View {
        NavigationStack {
            ScrollView {
                AssetGridView(records: records,
                              emptyTitle: "Nothing left here",
                              isLoading: isLoading,
                              selection: selection)
                    .padding(.bottom, Space.section)
            }
            // A sheet covers the app's tab bar, so the bar needs no room reserved under it.
            .safeAreaInset(edge: .bottom) {
                if selection.isActive {
                    SelectionActionBar(selection: selection)
                        .padding(.bottom, Space.m)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: selection.isActive)
            .background(Palette.canvas)
            .navigationTitle(event.placeName ?? "Occasion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            records = LibraryQuery.records(for: event.assetIdentifiers,
                                           context: app.container.mainContext)
            isLoading = false
        }
    }
}

/// Everything from one place in one year, opened from the list under the map.
private struct PlaceYearSheet: View {
    let entry: PlaceYear

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true
    @State private var selection = PhotoSelection()

    var body: some View {
        NavigationStack {
            ScrollView {
                AssetGridView(records: records,
                              emptyTitle: "Nothing left here",
                              isLoading: isLoading,
                              selection: selection)
                    .padding(.bottom, Space.section)
            }
            // A sheet covers the app's tab bar, so the bar needs no room reserved under it.
            .safeAreaInset(edge: .bottom) {
                if selection.isActive {
                    SelectionActionBar(selection: selection)
                        .padding(.bottom, Space.m)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: selection.isActive)
            .background(Palette.canvas)
            .navigationTitle("\(entry.place) · \(String(entry.year))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            records = LibraryQuery.records(for: entry.assetIdentifiers,
                                           context: app.container.mainContext)
            isLoading = false
        }
    }
}
