import SwiftUI

struct OnboardingFlowContainer: View {
    @Environment(AppModel.self) private var appModel
    @State private var store = OnboardingMockFactory.makeStore()

    var body: some View {
        OnboardingFlowView(store: store)
            .task {
                store = OnboardingStore(dependencies: appModel.onboardingDependencies)
            }
            .onChange(of: store.didComplete) { _, completed in
                guard completed else { return }
                appModel.applyOnboardingCompletion(from: store)
            }
    }
}

struct MemoriesRootScreen: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingBlockCandidate: MemoryCandidate?

    var body: some View {
        ZStack {
            AppBackgroundView(theme: appModel.appTheme)

            if appModel.feedCandidates.isEmpty {
                FeedCompletionView(
                    theme: appModel.appTheme,
                    onNewCycle: { appModel.startNewCycle() },
                    onExpandYears: {
                        var filter = appModel.currentFilter
                        filter.yearFrom = nil
                        filter.yearTo = nil
                        appModel.updateFilter(filter)
                    },
                    onChangeExplore: {
                        var filter = appModel.currentFilter
                        filter.selectionMode = filter.selectionMode == .smartRandom ? .pureRandom : .smartRandom
                        appModel.updateFilter(filter)
                    }
                )
            } else {
                MemoriesFeedView(
                    candidates: appModel.feedCandidates,
                    filter: Binding(
                        get: { appModel.currentFilter },
                        set: { appModel.updateFilter($0) }
                    ),
                    playbackCoordinator: appModel.playbackCoordinator,
                    sharingClient: appModel.sharingClient,
                    actionHandler: MemoryFeedActionHandler(
                        onSave: { appModel.toggleSaved($0) },
                        onBlock: { pendingBlockCandidate = $0 },
                        onDisplay: { appModel.markSeen($0) }
                    )
                )
            }
        }
        .alert("Block this memory?", isPresented: pendingBlockBinding) {
            Button("Cancel", role: .cancel) {
                pendingBlockCandidate = nil
            }
            Button("Block", role: .destructive) {
                guard let pendingBlockCandidate else { return }
                appModel.block(pendingBlockCandidate)
                self.pendingBlockCandidate = nil
            }
        } message: {
            Text("It will stop appearing in Memories until you unblock it.")
        }
    }

    private var pendingBlockBinding: Binding<Bool> {
        Binding(
            get: { pendingBlockCandidate != nil },
            set: { if !$0 { pendingBlockCandidate = nil } }
        )
    }
}

private struct FeedCompletionView: View {
    let theme: AppTheme
    let onNewCycle: () -> Void
    let onExpandYears: () -> Void
    let onChangeExplore: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppGlassCard(theme: theme) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("This cycle is complete", systemImage: "checkmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.primaryText)

                    Text("You have reached the end of the current filter cycle without repeating a memory.")
                        .foregroundStyle(theme.secondaryText)
                }
            }

            AppPrimaryButton(title: "Start New Cycle", systemImage: "arrow.clockwise", theme: theme, isEnabled: true, action: onNewCycle)
            AppSecondaryButton(title: "Expand Years", theme: theme, action: onExpandYears)
            AppSecondaryButton(title: "Change Explore", theme: theme, action: onChangeExplore)
        }
        .padding(20)
    }
}
