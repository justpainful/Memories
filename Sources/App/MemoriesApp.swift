import SwiftData
import SwiftUI

@main
struct MemoriesApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appModel)
        }
        .modelContainer(appModel.sharedModelContainer)
    }
}

