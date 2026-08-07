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
/// The three stacks stay alive behind one another so switching tabs keeps scroll position,
/// which is what the system bar would have given us and what the custom bar must not lose.
struct RootView: View {
    @Environment(\.app) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: AppTab = LaunchOptions.startTab ?? .memories
    @State private var isExploring = false
    @State private var exploreDestination: TimeWindow?

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

    private var shouldShowOnboarding: Bool {
        if LaunchOptions.skipsOnboarding { return false }
        return !app.hasSeenOnboarding || app.library.access == .notDetermined
    }

    private var main: some View {
        ZStack(alignment: .bottom) {
            ZStack {
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
        .animation(.smooth(duration: 0.42), value: isExploring)
        .sheet(item: $exploreDestination) { window in
            TimeWindowResultsView(window: window)
        }
    }

    /// Keeps every tab mounted; only the selected one is visible and interactive.
    private func surface<Content: View>(_ tab: AppTab,
                                        @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            .allowsHitTesting(selection == tab)
            .accessibilityHidden(selection != tab)
    }
}

#Preview {
    RootView()
}
