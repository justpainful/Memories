import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.isLoading {
                ZStack {
                    AppBackgroundView(theme: appModel.appTheme)
                    ProgressView()
                        .tint(.white)
                }
            } else if appModel.hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingFlowContainer()
            }
        }
        .task {
            await appModel.bootstrap()
        }
        .appTheme(appModel.appTheme)
    }
}
