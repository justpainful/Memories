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

    /// Registration happens once per process, never once per window.
    ///
    /// `BGTaskScheduler.register` raises if the same identifier is registered twice, and the
    /// call site is a `.task` on the root view — which runs once per scene. On iPhone there is
    /// only ever one scene so this never came up; now that the app can have two windows open
    /// on an iPad, the second one would abort the app on arrival.
    @MainActor private static var isRegistered = false

    @MainActor
    static func register(app: AppEnvironment) {
        guard !isRegistered else { return }
        isRegistered = true

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

        app.startIndexingIfPossible()

        let window = Task { @MainActor in
            // Hold the window open for as long as the pass needs it rather than for a fixed
            // handful of seconds. This is the one moment the phone is on power with nobody
            // looking at it, which is exactly when the expensive stages should be running —
            // handing the time back after twenty-five seconds meant a large library was
            // indexed almost entirely in the foreground, on battery, in front of the user.
            //
            // `try` rather than `try?`: cancellation has to leave without reporting success,
            // because the expiration handler has already reported failure.
            while app.coordinator.isRunning {
                try await Task.sleep(for: .seconds(2))
            }
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            // The system wants its time back. Cancelling the waiter is what stops completion
            // being reported twice, which is a crash rather than a mistake.
            window.cancel()
            app.coordinator.stop()
            task.setTaskCompleted(success: false)
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
