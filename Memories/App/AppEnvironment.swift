import Foundation
import Observation
import SwiftData
import SwiftUI

/// Everything long-lived, assembled once and handed down the view tree.
@MainActor
@Observable
final class AppEnvironment {
    let container: ModelContainer
    let library: PhotoLibraryService
    let coordinator: AnalysisCoordinator
    let settings: AppSettings

    /// Set once the user has been through onboarding, whatever they chose at the end of it.
    var hasSeenOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenOnboarding, forKey: "hasSeenOnboarding") }
    }

    init(inMemory: Bool = false) {
        let container = MemoryStore.makeContainer(inMemory: inMemory)
        let library = PhotoLibraryService()

        self.container = container
        self.library = library
        self.settings = AppSettings()
        self.coordinator = AnalysisCoordinator(container: container, library: library)
        self.hasSeenOnboarding = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")

        library.refreshAccess()
    }

    var feedback: MemoryFeedback { MemoryFeedback(context: container.mainContext) }

    func makeEngine() -> MemoryEngine { MemoryEngine(modelContainer: container) }

    /// Kick off indexing if we are allowed to and it is not already running.
    func startIndexingIfPossible() {
        guard library.access.canRead else { return }
        library.startObserving()
        coordinator.start()
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    @MainActor static let defaultValue = AppEnvironment(inMemory: true)
}

extension EnvironmentValues {
    var app: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
