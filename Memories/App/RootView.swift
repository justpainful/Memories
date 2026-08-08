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
        // `.leading`, not `.left`. SF Symbols publishes both, and the difference is the whole
        // point of the pair: `.left` draws the day column on the left whatever the layout
        // direction, so in a right-to-left layout the tab bar's one directional glyph points
        // back the way the reader came from. `.leading` mirrors with the interface.
        case .timeline: return "calendar.day.timeline.leading"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var selection: AppTab = LaunchOptions.startTab ?? .memories
    @State private var isExploring = false
    @State private var exploreDestination: TimeWindow?
    @State private var intentMemory: MemoryCandidate?

    /// What the floating bar measured at this launch, on this device, at this text size.
    @State private var measuredBarHeight: CGFloat = 0

    /// The bar's height plus a breath of air, which is what a scroll view should stop at.
    ///
    /// Content that ends exactly at the top edge of a floating control looks like content that
    /// has been cut off by it. The gap is what says the list finished.
    private var barInset: CGFloat {
        measuredBarHeight > 0 ? measuredBarHeight + Space.gutter : 132
    }

    var body: some View {
        Group {
            if shouldShowOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else {
                main
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35),
                   value: shouldShowOnboarding)
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
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                TabView(selection: $selection) {
                    surface(.memories) { HomeView() }
                    surface(.timeline) { TimelineView() }
                    surface(.library)  { LibraryView() }
                }
                // Every screen inside ends its scroll above the floating bar, using the height
                // the bar actually came out at rather than a number remembered from one phone.
                .environment(\.bottomBarInset, barInset)

                // Dim the content while the time panel is open so it reads as the front layer.
                if isExploring {
                    // Heavier when the reader has asked for less transparency or more contrast:
                    // eighteen percent is a hint that the layer underneath has gone quiet, and a
                    // hint is exactly what those two settings are turned on to stop relying on.
                    Color.black.opacity(reduceTransparency ? 0.65 : (contrast == .increased ? 0.4 : 0.18))
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { isExploring = false }
                        // Otherwise the only way out of the panel for a VoiceOver reader is the
                        // close button, and the dim is an unlabelled slab in the rotor.
                        .accessibilityLabel("Close Explore Time")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { isExploring = false }
                }

                ExploreTimeBar(selection: $selection,
                               isExploring: $isExploring,
                               onSelectWindow: { window in exploreDestination = window },
                               availableHeight: proxy.size.height,
                               measuredHeight: $measuredBarHeight)
            }
        }
        // The same curve and duration the bar animates itself on. Two layers move on this one
        // value — the panel and the dim behind it — and if they disagree the dim arrives
        // without its panel. That includes agreeing about Reduce Motion.
        .animation(reduceMotion ? .easeInOut(duration: ExploreTimeBar.morphDuration)
                                : .smooth(duration: ExploreTimeBar.morphDuration),
                   value: isExploring)
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
