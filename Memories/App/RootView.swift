import SwiftUI

enum AppTab: String, Hashable, CaseIterable, Identifiable {
    case memories, timeline, library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memories: return "Memories"
        case .timeline: return "Timeline"
        case .library:  return "Library"
        }
    }

    var symbol: String {
        switch self {
        case .memories: return "rectangle.stack"
        case .timeline: return "calendar.day.timeline.left"
        case .library:  return "square.grid.2x2"
        }
    }
}

/// Three tabs, as decided. Calendar, Places and Search are surfaces inside Timeline and
/// Library rather than tabs of their own.
///
/// Switching tabs keeps scroll position, which is what the system bar would have given us and
/// what the custom bar must not lose. That is `TabView`'s job, and this used to try to do it by
/// hand — three stacks mounted at once, the unselected two hidden with `.opacity(0)`.
///
/// It did not work, and it cost twice over. A `NavigationStack`'s bar is not drawn inside the
/// subtree the modifier applies to, so opacity never reached it: on device two navigation bars
/// appeared side by side and the one underneath would not go away, and the accessibility tree
/// listed all three at once. It was also three times the launch work — every tab ran its own
/// `.task` and fetched the whole library before anyone had asked to see it, which on a library
/// of this size is measured in seconds of a blocked screen.
struct RootView: View {
    @Environment(\.app) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: AppTab = LaunchOptions.startTab ?? .memories
    @State private var isExploring = false
    @State private var exploreDestination: TimeWindow?
    @State private var intentMemory: MemoryCandidate?

    var body: some View {
        Group {
            if shouldShowOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else {
                main
            }
        }
        .animation(.smooth(duration: 0.35), value: shouldShowOnboarding)
        .preferredColorScheme(app.settings.preferredColorScheme)
        .sheet(item: $intentMemory) { candidate in
            NavigationStack {
                MemoryDetailView(candidate: candidate)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { intentMemory = nil }
                        }
                    }
            }
        }
        // Drained on appearance as well as on arrival: a cold launch runs the intent before
        // this view exists, so by the time it does the request is already waiting.
        .task { await handleIntent() }
        .onChange(of: MemoryIntentRouter.shared.request) { _, _ in
            Task { await handleIntent() }
        }
        .task {
            BackgroundWork.register(app: app)
            // Skipping onboarding means behaving as if it had been completed, and completing
            // it is what asks for access.
            if LaunchOptions.skipsOnboarding, app.library.access == .notDetermined {
                await app.library.requestAccess()
            }
            app.startIndexingIfPossible()
            await MemoryNotifications.reschedule(app: app)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.library.refreshAccess()
                app.startIndexingIfPossible()
            case .background:
                // Indexing a large library should not require the user to sit and watch it.
                BackgroundWork.scheduleAnalysis()
                BackgroundWork.scheduleRefresh()
                Task { await MemoryNotifications.reschedule(app: app) }
            default:
                break
            }
        }
    }

    @MainActor
    private func handleIntent() async {
        guard let target = MemoryIntentRouter.shared.take() else { return }
        switch target {
        case .window(let window):
            // Presenting the sheet in the same tick that starts the panel folding back into the
            // bar leaves that morph running underneath it, and a glass morph interrupted
            // half-way is a smear across the bottom of the screen rather than a control. The
            // panel is given its own animation to finish before the sheet arrives on top.
            if isExploring {
                isExploring = false
                try? await Task.sleep(for: .seconds(ExploreTimeBar.morphDuration))
            }
            exploreDestination = window
        case .topMemory:
            intentMemory = await MemoryIntentRouter.topMemory(app: app)
        }
    }

    private var shouldShowOnboarding: Bool {
        if LaunchOptions.skipsOnboarding { return false }
        return !app.hasSeenOnboarding || app.library.access == .notDetermined
    }

    private var main: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                surface(.memories) { HomeView() }
                surface(.timeline) { TimelineView() }
                surface(.library)  { LibraryView() }
            }

            // Dim the content while the time panel is open so it reads as the front layer.
            if isExploring {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { isExploring = false }
            }

            ExploreTimeBar(selection: $selection, isExploring: $isExploring) { window in
                exploreDestination = window
            }
        }
        // The same curve and duration the bar animates itself on. Two layers move on this one
        // value — the panel and the dim behind it — and if they disagree the dim arrives
        // without its panel.
        .animation(.smooth(duration: ExploreTimeBar.morphDuration), value: isExploring)
        .sheet(item: $exploreDestination) { window in
            TimeWindowResultsView(window: window)
        }
    }

    /// One tab.
    ///
    /// `TabView` is wanted for what it does underneath — one stack in the hierarchy at a time,
    /// state kept across switches — and not for its bar, which this app replaces. Each tab
    /// hides that bar from inside its own navigation stack, which is where the modifier has to
    /// sit to be heard; the app draws `ExploreTimeBar` in its place, because the specification
    /// asks for the toolbar's glass to *become* the time panel and that morph is only possible
    /// when one `GlassEffectContainer` owns both states.
    private func surface<Content: View>(_ tab: AppTab,
                                        @ViewBuilder content: () -> Content) -> some View {
        content().tag(tab)
    }
}

#Preview {
    RootView()
}
