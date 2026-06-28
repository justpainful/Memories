import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView(selection: tabBinding) {
            MemoriesRootScreen()
                .tabItem { Label(RootTab.memories.title, systemImage: RootTab.memories.symbol) }
                .tag(RootTab.memories)

            LibraryRootScreen()
                .tabItem { Label(RootTab.library.title, systemImage: RootTab.library.symbol) }
                .tag(RootTab.library)

            BlockedRootScreen()
                .tabItem { Label(RootTab.blocked.title, systemImage: RootTab.blocked.symbol) }
                .tag(RootTab.blocked)

            ProfileRootScreen()
                .tabItem { Label(RootTab.profile.title, systemImage: RootTab.profile.symbol) }
                .tag(RootTab.profile)
        }
        .tint(appModel.appTheme.accent)
    }

    private var tabBinding: Binding<RootTab> {
        Binding(
            get: { appModel.selectedTab },
            set: { appModel.selectedTab = $0 }
        )
    }
}
