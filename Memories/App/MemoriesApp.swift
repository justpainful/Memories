import SwiftUI

@main
struct MemoriesApp: App {
    /// Owned here so there is exactly one of it, and so the real on-disk store is what the
    /// app runs on. Without this the environment falls back to its default value, which is
    /// an in-memory container — everything would work for one session and persist nothing.
    @State private var app = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.app, app)
                .modelContainer(app.container)
                .tint(Palette.accent)
        }
    }
}

/// Flags CI passes at launch so it can screenshot past the permission screen and open a
/// given surface. Read straight from the process arguments rather than through
/// `UserDefaults`, so behaviour does not depend on argument-domain parsing.
enum LaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var skipsOnboarding: Bool { arguments.contains("-skipOnboarding") }

    static var startTab: AppTab? {
        guard let index = arguments.firstIndex(of: "-startTab"),
              arguments.indices.contains(index + 1) else { return nil }
        return AppTab(rawValue: arguments[index + 1])
    }
}
