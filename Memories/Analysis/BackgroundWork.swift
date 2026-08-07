import BackgroundTasks
import Foundation

/// Lets indexing continue after the user leaves, so a first run on a large library is not
/// something they have to sit and watch.
///
/// The identifiers here must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist, or
/// registration throws at launch.
enum BackgroundWork {
    static let analysisIdentifier = "com.justpainful.Memories.analysis"
    static let refreshIdentifier = "com.justpainful.Memories.refresh"

    @MainActor
    static func register(app: AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: analysisIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in handleAnalysis(task, app: app) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in handleRefresh(task, app: app) }
        }
    }

    /// Ask for time to keep indexing. Requires power and does not need the network, because
    /// nothing here talks to a network.
    static func scheduleAnalysis() {
        let request = BGProcessingTaskRequest(identifier: analysisIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Keep the scheduled Lock Screen memories in step with a library that keeps changing.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Handlers

    @MainActor
    private static func handleAnalysis(_ task: BGProcessingTask, app: AppEnvironment) {
        scheduleAnalysis()   // always queue the next one first

        task.expirationHandler = {
            app.coordinator.stop()
            task.setTaskCompleted(success: false)
        }

        app.startIndexingIfPossible()
        Task {
            // Give it a working window, then hand time back rather than being killed for it.
            try? await Task.sleep(for: .seconds(25))
            let finished = !app.coordinator.isRunning
            task.setTaskCompleted(success: finished)
        }
    }

    @MainActor
    private static func handleRefresh(_ task: BGAppRefreshTask, app: AppEnvironment) {
        scheduleRefresh()

        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Task {
            await MemoryNotifications.reschedule(app: app)
            task.setTaskCompleted(success: true)
        }
    }
}
