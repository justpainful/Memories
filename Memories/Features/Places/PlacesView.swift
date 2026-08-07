import CoreLocation
import MapKit
import Observation
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

    /// The year on its own, without a thousands separator: it is a label, not a quantity, and
    /// "2,019" is what a number formatter will make of it if it is not told otherwise.
    var yearText: String { year.formatted(.number.grouping(.never)) }

    /// What the row says out loud.
    ///
    /// On screen the place is the section header above the row, which is fine for an eye that
    /// can see both at once and useless to somebody swiping row to row — by the fourth year
    /// under Lisbon the header was four swipes ago. The sheet this opens is titled with the
    /// place and the year, so the row was announcing strictly less than what it opened. The
    /// count carries its unit for the same reason: "41" is not an answer to anything.
    var spokenLabel: String {
        let photos = count == 1 ? "photo" : "photos"
        return "\(place), \(yearText), \(count.formatted()) \(photos)"
    }
}

/// One place, with each of its years under it — the shape the list below the map is drawn in.
private struct PlaceGroup: Identifiable {
    let name: String
    let years: [PlaceYear]

    var id: String { name }
}

// MARK: - Naming the coordinates

/// Working out what the coordinates on an occasion are called, for the whole library.
///
/// This used to be a private method on `PlacesView` that ran over `events.prefix(24)` when the
/// screen appeared, and the consequences reached far past this screen. `placeName` is written
/// in exactly one place in the app, so twenty-four names was the *total* supply: Best Of's
/// Places section said "none have been worked out yet" forever, searching for a place matched
/// nothing, and the memory engine's entire `.place` kind — one of twelve — could never fire.
/// A user who never opened Library › Places got none of it at all. Capping the work was the
/// right instinct in the wrong place: the cost of geocoding is calls to a rate-limited service,
/// not a number of occasions, and the answer to that is spacing and reuse, not a cliff at 24.
///
/// So it is a service rather than a screen's side effect, and it holds three things the old
/// loop could not:
///
/// - **Reuse.** People photograph the same handful of places over and over, so occasions are
///   asked about by rounded coordinate and a place named once is never asked about again. A
///   library with four hundred located occasions usually needs a couple of dozen lookups.
/// - **Resumption.** Nothing is remembered except what was written: an occasion still holding
///   `placeName == nil` is one still owing. Stopping the app in the middle costs nothing, and
///   starting the pass again is safe from anywhere at any time.
/// - **Giving up honestly.** Reverse geocoding is the one call this app makes off the device,
///   and off a network it simply fails. Three failures in a row and the pass stops and says so,
///   rather than walking a thousand occasions failing at each one.
///
/// It lives in this file because this is the file that owns place names today, and the screens
/// that need names start it. That is still one step short of where it belongs: the right home
/// is a stage in `AnalysisCoordinator.run()`, alongside the passes that build the occasions it
/// reads — one `await PlaceNaming.shared.run(container: container)` after `rebuildGroups()`.
/// `run(container:)` is written to be called exactly that way, and nothing here would change.
@MainActor
@Observable
final class PlaceNaming {
    static let shared = PlaceNaming()

    /// Where the pass has got to. The screens that show place names have three different
    /// silences to explain and cannot tell them apart from an empty list alone.
    enum Progress {
        /// Never run in this launch.
        case idle
        /// Walking the occasions now.
        case working
        /// Every located occasion has been offered to the geocoder and answered for.
        case settled
        /// The geocoder stopped answering. Not a permanent state — the next `start` retries.
        case stalled
    }

    private(set) var progress: Progress = .idle
    /// Bumped once per name written, so a screen can regroup as the answers land instead of
    /// on the next visit.
    private(set) var namedCount = 0

    private var task: Task<Void, Never>?
    /// Which pass the running task belongs to. A pass that was stopped still has to finish
    /// unwinding, and without this its last line would clear the handle of whichever pass had
    /// started in the meantime — after which nothing could start another one.
    private var runID = 0
    /// Rounded coordinate to the name that came back for it. Lives for the process, which is
    /// as long as it is useful: what is worth keeping is already on the occasions.
    private var resolved: [String: String] = [:]
    /// Coordinates the geocoder answered about with nothing at all — mid-ocean, deep desert.
    /// Asking again in the same launch would get the same silence at the same cost.
    private var unnameable: Set<String> = []

    private init() {}

    /// Start a pass, or leave the one already running alone.
    ///
    /// Safe to call from anywhere, as often as you like: it is how new occasions get named
    /// without anybody having to work out which ones are new.
    func start(in app: AppEnvironment) {
        guard task == nil, app.library.access.canRead else { return }
        let container = app.container
        runID += 1
        let id = runID
        progress = .working
        task = Task { [weak self] in
            await self?.run(container: container)
            self?.finish(id)
        }
    }

    /// Start a pass from the indexer, which has a container and no `AppEnvironment`.
    ///
    /// Detached from the caller on purpose. This is called at the end of the occasion-building
    /// stage, and the pass it starts is spaced out over minutes because reverse geocoding is
    /// rate-limited by somebody else's service. Awaiting it there would hold the indexing pass
    /// open for the whole of that, and the app would go on saying it was still reading the
    /// library long after it had finished.
    func startDetached(container: ModelContainer) {
        guard task == nil else { return }
        runID += 1
        let id = runID
        progress = .working
        task = Task { [weak self] in
            await self?.run(container: container)
            self?.finish(id)
        }
    }

    /// Stop the pass where it stands. Everything already written stays written.
    func stop() {
        task?.cancel()
        task = nil
        runID += 1
        if case .working = progress { progress = .idle }
    }

    private func finish(_ id: Int) {
        guard id == runID else { return }
        task = nil
    }

    /// The pass itself, awaitable.
    ///
    /// `start(in:)` is the fire-and-forget form the screens use. This one is here so the pass
    /// can be dropped straight into `AnalysisCoordinator.run()` as a stage, which is where it
    /// belongs: one `await PlaceNaming.shared.run(container: container)` after the occasions
    /// have been rebuilt, and no screen ever has to think about place names again.
    func run(container: ModelContainer) async {
        let context = container.mainContext
        let descriptor = FetchDescriptor<EventCluster>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        // Newest first, so the places a user is most likely to go looking for arrive first even
        // though every one of them will be reached.
        let owing = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.latitude != nil && $0.placeName == nil }

        guard !owing.isEmpty else {
            progress = .settled
            return
        }

        let geocoder = CLGeocoder()
        var consecutiveFailures = 0

        for event in owing {
            guard !Task.isCancelled else { return }
            guard let latitude = event.latitude, let longitude = event.longitude else { continue }
            let key = Self.key(latitude: latitude, longitude: longitude)

            // A place already worked out costs nothing, so it does not spend the pause either.
            if let known = resolved[key] {
                apply(known, to: event, in: context)
                continue
            }
            if unnameable.contains(key) { continue }

            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(
                    CLLocation(latitude: latitude, longitude: longitude)
                )
                consecutiveFailures = 0
                if let name = placemarks.first.flatMap({ Self.name(from: $0) }) {
                    resolved[key] = name
                    apply(name, to: event, in: context)
                } else {
                    unnameable.insert(key)
                }
            } catch {
                consecutiveFailures += 1
                guard consecutiveFailures < 3 else {
                    progress = .stalled
                    return
                }
                // One failure is a hiccup and is worth waiting out; this occasion is left owing
                // and the next pass will reach it again.
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            // Well inside the geocoder's rate limit. The sleep is the reason this is a pass and
            // not a loop: it is what keeps a library of hundreds from being refused wholesale.
            try? await Task.sleep(for: .milliseconds(250))
        }

        progress = .settled
    }

    /// Written one at a time rather than in a batch at the end. A pass over a large library
    /// takes minutes, and a name that is known but not saved is a name the rest of the app
    /// still cannot see.
    private func apply(_ name: String, to event: EventCluster, in context: ModelContext) {
        event.placeName = name
        context.saveIfNeeded()
        namedCount += 1
    }

    /// Two decimal places is a bit over a kilometre, which is about the distance at which a
    /// person stops calling somewhere by a different name.
    private static func key(latitude: Double, longitude: Double) -> String {
        let lat = Int((latitude * 100).rounded())
        let lon = Int((longitude * 100).rounded())
        return "\(lat)/\(lon)"
    }

    private static func name(from placemark: CLPlacemark) -> String? {
        placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? placemark.country
    }
}

// MARK: - The screen

/// Where your photographs were taken, from the coordinates your camera already saved.
///
/// Not a Google Photos clone: the map is a way in, and what it leads to is the same thing
/// the rest of the app deals in — years, occasions and memories from that place.
struct PlacesView: View {
    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    /// The screen splits differently when it is wider than it is tall, which is the one thing
    /// a map and a list under it cannot both survive.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var events: [EventCluster] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: EventCluster?
    @State private var openYear: PlaceYear?
    /// Grouped once per load rather than once per redraw. Built in `body` it re-ran the whole
    /// group-and-sort every time the list scrolled a row in or a place name arrived from the
    /// geocoder, which on a library with a few hundred occasions is work done for nothing.
    @State private var groupedByPlace: [PlaceGroup] = []
    /// The size this screen was actually given, which is the only number the map's share of it
    /// can honestly be derived from.
    @State private var containerSize: CGSize = .zero

    var body: some View {
        Group {
            if events.isEmpty {
                QuietStatusView(
                    title: "No places yet",
                    detail: "Photos need location saved by your camera for them to appear here.",
                    symbol: "mappin.slash"
                )
            } else if isSideBySide {
                // Turned sideways, or on an iPad, a map stacked on a list leaves the list a
                // two-row sliver. Maps and Photos both put them beside each other at these
                // sizes, and so does this.
                HStack(spacing: 0) {
                    map.frame(width: mapWidth)
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(width: 1)
                    placesList
                }
            } else {
                VStack(spacing: 0) {
                    map.frame(height: mapHeight)
                    placesList
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
            containerSize = new
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
        // Names arrive one at a time over minutes, and a place that has just been named belongs
        // in the list under the map now, not on the next visit.
        .onChange(of: PlaceNaming.shared.namedCount) { _, _ in regroup() }
        // Occasions are built by the indexing pass, so the end of a pass is when there is most
        // likely to be something new here to name.
        .onChange(of: app.coordinator.isRunning) { _, isRunning in
            if !isRunning { PlaceNaming.shared.start(in: app) }
        }
    }

    // MARK: Proportions

    /// Side by side when the container is short or wide; stacked otherwise.
    private var isSideBySide: Bool {
        verticalSizeClass == .compact || horizontalSizeClass == .regular
    }

    /// The map's share of the height, rather than the 280 points it used to be given whatever
    /// it was standing in. In landscape that constant was most of the screen and the list under
    /// it was a rumour; on a 1366-point iPad it was a fifth of the screen with a thousand
    /// points of list running on below.
    private var mapHeight: CGFloat {
        guard containerSize.height > 0 else { return 280 }
        return min(max(containerSize.height * 0.38, 200), 460)
    }

    private var mapWidth: CGFloat {
        guard containerSize.width > 0 else { return 320 }
        return min(max(containerSize.width * 0.45, 260), 520)
    }

    // MARK: The map

    private var map: some View {
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
                                PhotoThumbnail(identifier: cover, side: Hit.min, radius: 10)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(.white, lineWidth: 2)
                                    }
                                    .shadow(radius: 3)
                                    .contentShape(.rect(cornerRadius: 10))
                            } else {
                                // A pin drawn at label size is a 17-point target on a map you
                                // are already fighting for a finger's worth of space on. The
                                // glyph does not scale with the reader's type either: it is a
                                // pin on a map, sized by the map, and what a reader who needs
                                // larger text is served by is the label below.
                                Image(systemName: "mappin.circle.fill")
                                    .font(Typo.glyph(26, .regular))
                                    .foregroundStyle(Palette.accent, .white)
                                    .frame(width: Hit.min, height: Hit.min)
                                    .contentShape(.circle)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(spokenLabel(for: event))
                    }
                }
            }
        }
    }

    /// A pin announced as its place name alone said nothing about which of the several
    /// occasions there it was. The date is what tells them apart, and the count is what says
    /// whether it is worth opening.
    private func spokenLabel(for event: EventCluster) -> String {
        let when = event.startDate.formatted(date: .abbreviated, time: .omitted)
        let count = event.assetCount
        let photos = count == 1 ? "photo" : "photos"
        let tally = "\(count.formatted()) \(photos)"
        guard let place = event.placeName, !place.isEmpty else {
            return "An occasion, \(when), \(tally)"
        }
        return "\(place), \(when), \(tally)"
    }

    // MARK: The list

    @ViewBuilder
    private var placesList: some View {
        if groupedByPlace.isEmpty {
            // There are located occasions and none of them has a name yet. This drew as several
            // hundred points of empty list under the map, which reads as a screen that is
            // broken rather than as one that is working.
            ScrollView {
                namingStatus.padding(.top, Space.section)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
        } else {
            List {
                ForEach(groupedByPlace) { group in
                    Section(group.name) {
                        ForEach(group.years) { entry in
                            Button { openYear = entry } label: {
                                HStack {
                                    Text(entry.yearText)
                                        .font(Typo.label)
                                        .foregroundStyle(Palette.textPrimary)
                                    // A minimum keeps the count from being crushed against the
                                    // year when the reader's type is large.
                                    Spacer(minLength: Space.s)
                                    Text(entry.count.formatted())
                                        .font(Typo.meta)
                                        .foregroundStyle(Palette.textTertiary)
                                        .monospacedDigit()
                                }
                                // A line of type is eighteen points tall and this row opens a
                                // whole year of a place. The floor is stated rather than padded
                                // up to, so it still holds if the type grows.
                                .frame(minHeight: Hit.min)
                                .contentShape(.rect)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(entry.spokenLabel)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
            // A list of years stretched across an iPad is a four-digit number with a two-digit
            // number a foot away from it.
            .readableMeasure()
        }
    }

    /// Three silences, three different things to say. "Nothing here" would be wrong for all of
    /// them: the photographs exist and their coordinates exist, and what is missing is a name.
    @ViewBuilder
    private var namingStatus: some View {
        switch PlaceNaming.shared.progress {
        case .idle, .working:
            QuietStatusView(
                title: "Working out where these are",
                detail: "Place names are looked up from the coordinates your camera saved. Nothing else leaves the device.",
                symbol: "mappin.and.ellipse"
            )
        case .stalled:
            QuietStatusView(
                title: "Couldn’t look these places up",
                detail: "Turning coordinates into names is the one thing this app asks the network for. It will try again next time you are online.",
                symbol: "wifi.slash"
            )
        case .settled:
            QuietStatusView(
                title: "Couldn’t name these places",
                detail: "The coordinates are there, but nothing came back with a name for them.",
                symbol: "mappin.slash"
            )
        }
    }

    // MARK: Data

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
        // Not awaited and not this screen's work any more. Opening Places is simply one of the
        // moments it is worth making sure the naming pass is running.
        PlaceNaming.shared.start(in: app)
    }
}

/// One occasion, opened from its pin on the map.
private struct EventPlaceSheet: View {
    let event: EventCluster

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        // A bar sliding up from the bottom edge is a position change, which is
                        // the class of motion the setting exists to suppress. Cross-dissolved
                        // it still announces itself without travelling.
                        .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selection.isActive)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selection.isActive)
            .background(Palette.canvas)
            .navigationTitle(title)
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

    /// A place name and a year on either side of a middle dot, and the dot belongs to neither.
    ///
    /// `·` is bidi-neutral and a year is a run of Western digits, so with a right-to-left place
    /// name the two ends of this title were free to swap around the dot — "Lisbon · 2019" one
    /// row and the year first on the next, depending on what the place happened to be called.
    /// The first-strong isolates fence each run off so neither can drag the other, which is
    /// what they are for.
    private var title: String {
        "\u{2068}\(entry.place)\u{2069} · \u{2068}\(entry.yearText)\u{2069}"
    }
}
