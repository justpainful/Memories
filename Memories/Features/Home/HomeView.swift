import SwiftData
import SwiftUI

/// The feed. A personal magazine that is different tomorrow, not a grid of files.
struct HomeView: View {
    @Environment(\.app) private var app
    /// The floating glass bar is not a system tab bar, so nothing inserts an inset for it. It
    /// measures itself and publishes the answer here; every screen used to write `132` instead,
    /// a number taken once from one phone at the default text size.
    @Environment(\.bottomBarInset) private var bottomBarInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = HomeModel()
    @State private var openCandidate: MemoryCandidate?
    @State private var quickWindow: TimeWindow?
    @State private var viewerRequest: FeedViewerRequest?

    /// The size of the container the feed was actually given — not the screen, which is a
    /// different number in Split View, in Slide Over and in Stage Manager. The hero card, the
    /// mosaic and both card rows are proportions of it, and the ambient wash is a fraction of
    /// its height.
    @State private var containerSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Palette.canvas.ignoresSafeArea()
                AmbientWash(identifier: model.candidates.first?.coverIdentifier,
                            containerHeight: containerSize.height)

                ScrollView {
                    // Tighter than the section gap: the masthead and the first memory belong
                    // to each other, and 40pt of white between them read as a loading state.
                    LazyVStack(alignment: .leading, spacing: Space.xl) {
                        VStack(alignment: .leading, spacing: Space.m) {
                            dateHeadline
                            quickTimeFilters
                        }

                        if model.candidates.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                                memorySection(candidate, isHero: index == 0)
                            }
                        }
                    }
                    // Clears the floating glass bar.
                    .padding(.bottom, bottomBarInset)
                }
                .scrollIndicators(.hidden)
                // Lets the navigation bar's own Liquid Glass meet the feed with a soft
                // falloff instead of a hard edge, which is what stops a floating bar over
                // photography from looking like a pasted-on rectangle.
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            // Read here rather than with a `GeometryReader`, which would take all the space in
            // both directions and collapse the scroll view's content height to nothing.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                containerSize = size
            }
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.large)
            // The app draws its own bar; this one would sit underneath it. The modifier has to
            // be inside the navigation stack to be heard, not wrapped around the tab.
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Curation", selection: Binding(
                            get: { app.settings.smartCuration ? CurationMode.smart : .pure },
                            set: { app.settings.smartCuration = $0 == .smart }
                        )) {
                            Text("Smart").tag(CurationMode.smart)
                            Text("Pure").tag(CurationMode.pure)
                        }
                        Divider()
                        Button("Refresh memories", systemImage: "arrow.clockwise") {
                            Task { await model.reload(app: app) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
                // Settings deserves one tap from the first screen, not a trip through a menu.
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(item: $openCandidate) { candidate in
                MemoryDetailView(candidate: candidate)
            }
            .sheet(item: $quickWindow) { window in
                TimeWindowResultsView(window: window)
            }
            .fullScreenCover(item: $viewerRequest) { request in
                PhotoViewerView(identifiers: request.identifiers, startAt: request.startAt)
            }
        }
        .task { await model.loadIfNeeded(app: app) }
        .onChange(of: app.settings.smartCuration) { _, _ in
            Task { await model.reload(app: app) }
        }
        .onChange(of: app.library.changeGeneration) { _, _ in
            Task { await model.loadIfNeeded(app: app) }
        }
        // The feed is built the moment the view appears, which on a first run is before
        // there is anything to build it from. Without this it would stay empty until the
        // calendar day changed.
        //
        // Both go through `loadIfNeeded` rather than forcing a rebuild. Indexing stops every
        // time the app is brought forward — the pass starts, finds nothing to do and ends —
        // and rebuilding for that re-ordered the page under whoever was reading it and counted
        // every memory on it as shown again, which is what pushes a memory out of tomorrow.
        .onChange(of: app.coordinator.hasUsableIndex) { _, usable in
            if usable { Task { await model.loadIfNeeded(app: app) } }
        }
        .onChange(of: app.coordinator.isRunning) { _, running in
            if !running {
                Task {
                    await model.loadIfNeeded(app: app)
                    announceReady()
                }
            }
        }
    }

    // MARK: Pieces

    private var dateHeadline: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(Typo.dateHeadline)
                .foregroundStyle(Palette.textPrimary)

            if app.coordinator.isRunning {
                Text(app.coordinator.statusLine)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
                    .transition(.opacity)
                    // On a first run this line is the only sign that anything is happening, and
                    // it changes as each stage finishes. Without the trait a reader who lands on
                    // it hears whatever it said when they arrived and is never told it moved on.
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, Space.gutter)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: app.coordinator.isRunning)
    }

    /// Time is the interface, so the common jumps sit on the first screen rather than
    /// behind the Explore control. The full set is still one tap away in the glass bar.
    private var quickTimeFilters: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(TimeWindow.quickFilters) { window in
                        GlassChip(title: window.title) {
                            quickWindow = window
                            Haptics.impact(.light)
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
                // Liquid Glass renders slightly outside the view's own bounds; without room
                // for it the scroll view clips the top and bottom off every capsule.
                .padding(.vertical, 8)
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var emptyState: some View {
        // Access is checked first. Telling someone their memories are being prepared when the
        // app cannot see a single photo is the kind of thing that never resolves and never
        // explains itself.
        if !app.library.access.canRead {
            QuietStatusView(
                title: "Memories can’t see your photos",
                detail: "Photo access is \(app.library.access.title.lowercased()). Grant access in Settings and your memories will start appearing.",
                symbol: "lock",
                // Naming the fix and then leaving the reader to find it themselves, on the
                // first screen of the app, in the one state where nothing works at all.
                actionTitle: "Open Settings",
                action: { openSystemSettings() }
            )
        } else if model.isBuilding || app.coordinator.isRunning || !app.coordinator.hasUsableIndex {
            // `isBuilding` belongs here as much as the other two. Without it the page announced
            // "Nothing to remember yet" for the second or so it takes to assemble the feed and
            // then filled with memories, which is a screen calling itself broken.
            QuietStatusView(
                title: "Getting your memories ready",
                detail: "They will appear here as they are found. You can keep using the app while this happens.",
                symbol: "sparkles"
            )
        } else if app.library.access == .limited {
            QuietStatusView(
                title: "Only a few photos are shared with Memories",
                detail: "Choose more photos to give the app more to work with.",
                symbol: "photo.on.rectangle",
                // Apple hands us this sheet for exactly this moment, and the app was sending
                // people out to the Settings app instead — out of Memories, into a tree of
                // system screens, to find a list of photographs and come back. The picker is
                // one tap and never leaves. Settings stays as the fallback for the case where
                // there is no window to present from at all.
                actionTitle: "Select More Photos…",
                action: {
                    if !app.library.presentLimitedLibraryPicker() { openSystemSettings() }
                }
            )
        } else {
            QuietStatusView(
                title: "Nothing to remember yet",
                detail: app.coordinator.indexedCount > 0
                    ? "\(app.coordinator.indexedCount.formatted()) photos are indexed, but none of them make a memory yet. Memories build up as your library spans more time."
                    : "Once there are photos in your library, memories will start appearing here.",
                symbol: "rectangle.stack"
            )
        }
    }

    @ViewBuilder
    private func memorySection(_ candidate: MemoryCandidate, isHero: Bool) -> some View {
        // The first memory of the day always gets the full-bleed treatment, whatever shape
        // it would otherwise take: the page needs one thing to open on.
        if isHero {
            Button { open(candidate) } label: {
                HeroMemoryCard(candidate: candidate, containerSize: containerSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary(candidate))
            .accessibilityIdentifier("memory.card")
        } else {
            VStack(alignment: .leading, spacing: Space.l) {
                Button { open(candidate) } label: {
                    SectionHeader(
                        overline: candidate.kind.fallbackTitle,
                        title: candidate.title,
                        subtitle: candidate.subtitle
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summary(candidate))
                // Both traits: it opens the memory, and it is the thing the headings rotor
                // should stop on when skipping from one memory to the next.
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("memory.card")

                switch candidate.presentation {
                case .single:
                    Button { open(candidate) } label: {
                        HeroMemoryCard(candidate: candidate, containerSize: containerSize)
                    }
                    .buttonStyle(.plain)

                case .mosaic:
                    Button { open(candidate) } label: {
                        MosaicSection(identifiers: candidate.assetIdentifiers,
                                      containerWidth: containerSize.width)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(summary(candidate))

                case .strip:
                    StripSection(identifiers: candidate.assetIdentifiers,
                                 containerWidth: containerSize.width) { identifier in
                        openViewer(candidate,
                                   identifiers: candidate.assetIdentifiers,
                                   at: identifier)
                    }

                case .throughTheYears:
                    YearStripSection(slices: model.yearSlices[candidate.id] ?? [],
                                     containerWidth: containerSize.width) { slice in
                        openViewer(candidate,
                                   identifiers: slice.assetIdentifiers,
                                   at: slice.coverIdentifier ?? slice.assetIdentifiers.first)
                    }
                }
            }
        }
    }

    // MARK: Opening

    private func open(_ candidate: MemoryCandidate) {
        app.feedback.recordOpened(candidate)
        openCandidate = candidate
        Haptics.impact()
    }

    /// Open the viewer on the photograph the finger actually landed on.
    ///
    /// Both card rows used to hand every card the same argument-less closure, so the twelfth
    /// frame in a strip opened the first and every column of a "through the years" memory
    /// produced a byte-identical result — five buttons pretending to be one, in the control the
    /// whole app is built around. The card always knew which asset it had drawn; the only thing
    /// missing was passing it back.
    ///
    /// The fall back to the memory itself is not defensive tidiness: a year with no cover and no
    /// assets is a real state during a rebuild, and opening a viewer on nothing is worse than
    /// opening the memory.
    private func openViewer(_ candidate: MemoryCandidate,
                            identifiers: [String],
                            at identifier: String?) {
        guard let identifier, identifiers.contains(identifier) else {
            open(candidate)
            return
        }
        app.feedback.recordOpened(candidate)
        viewerRequest = FeedViewerRequest(identifiers: identifiers, startAt: identifier)
        Haptics.impact()
    }

    // MARK: Announcements

    /// Tell a reader who cannot see the page that it has arrived.
    ///
    /// A first run leaves the feed empty for minutes while Vision works. A sighted reader watches
    /// the status line tick over and then sees memories appear; without this the same moment is
    /// silent, and the screen the reader is still sitting on has quietly filled underneath them.
    private func announceReady() {
        guard app.coordinator.hasUsableIndex, !model.candidates.isEmpty else { return }
        AccessibilityNotification.Announcement(app.coordinator.statusLine).post()
    }

    // MARK: Text

    /// What VoiceOver hears in place of the memory's title alone.
    ///
    /// The count carries its unit, because a bare number read out after a place name is heard as
    /// a year at least as often as a quantity.
    private func summary(_ candidate: MemoryCandidate) -> String {
        [candidate.title,
         candidate.subtitle,
         "\(candidate.assetCount.formatted()) photos"]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// What the feed opens the viewer with: the run of photographs the tapped card belongs to, and
/// the one under the finger. `fullScreenCover(item:)` needs an `Identifiable`, and a pair of
/// strings is not one.
struct FeedViewerRequest: Identifiable {
    let identifiers: [String]
    let startAt: String
    var id: String { startAt }
}
