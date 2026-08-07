import SwiftData
import SwiftUI

/// The feed. A personal magazine that is different tomorrow, not a grid of files.
struct HomeView: View {
    @Environment(\.app) private var app
    @State private var model = HomeModel()
    @State private var openCandidate: MemoryCandidate?
    @State private var quickWindow: TimeWindow?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Palette.canvas.ignoresSafeArea()
                AmbientWash(identifier: model.candidates.first?.coverIdentifier)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.section) {
                        VStack(alignment: .leading, spacing: Space.l) {
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
                    // Clears the floating glass bar; the bar is not a system tab bar, so
                    // nothing inserts this inset for us.
                    .padding(.bottom, 132)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.large)
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
        }
        .task { await model.loadIfNeeded(app: app) }
        .onChange(of: app.settings.smartCuration) { _, _ in
            Task { await model.reload(app: app) }
        }
        .onChange(of: app.library.changeGeneration) { _, _ in
            Task { await model.loadIfNeeded(app: app) }
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
            }
        }
        .padding(.horizontal, Space.gutter)
        .animation(.easeInOut(duration: 0.3), value: app.coordinator.isRunning)
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
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var emptyState: some View {
        if app.coordinator.isRunning || !app.coordinator.hasUsableIndex {
            QuietStatusView(
                title: "Getting your memories ready",
                detail: "They will appear here as they are found. You can keep using the app while this happens.",
                symbol: "sparkles"
            )
        } else if app.library.access == .limited {
            QuietStatusView(
                title: "Only a few photos are shared with Memories",
                detail: "Choose more photos in Settings to give the app more to work with.",
                symbol: "photo.on.rectangle"
            )
        } else {
            QuietStatusView(
                title: "Nothing to remember yet",
                detail: "Once there are photos in your library, memories will start appearing here.",
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
                HeroMemoryCard(candidate: candidate)
            }
            .buttonStyle(.plain)
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

                switch candidate.presentation {
                case .single:
                    Button { open(candidate) } label: {
                        HeroMemoryCard(candidate: candidate)
                    }
                    .buttonStyle(.plain)

                case .mosaic:
                    Button { open(candidate) } label: {
                        MosaicSection(identifiers: candidate.assetIdentifiers)
                    }
                    .buttonStyle(.plain)

                case .strip:
                    StripSection(identifiers: candidate.assetIdentifiers)

                case .throughTheYears:
                    YearStripSection(slices: model.yearSlices[candidate.id] ?? [])
                }
            }
        }
    }

    private func open(_ candidate: MemoryCandidate) {
        app.feedback.recordOpened(candidate)
        openCandidate = candidate
        Haptics.impact()
    }
}
