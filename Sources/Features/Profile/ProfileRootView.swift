import SwiftUI

struct ProfileRootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView(theme: appModel.appTheme)

                ScrollView {
                    VStack(spacing: 18) {
                        profileHeader
                        statsCard
                        controlsCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Profile")
        }
    }

    private var profileHeader: some View {
        AppGlassCard(theme: appModel.appTheme) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(appModel.appTheme.secondaryAccent.opacity(0.20))
                    Text(appModel.profile.fallbackInitials)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(appModel.appTheme.primaryText)
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 6) {
                    Text(appModel.profile.displayName.isEmpty ? "Memories" : appModel.profile.displayName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(appModel.appTheme.primaryText)
                    Text("Private on this iPhone")
                        .foregroundStyle(appModel.appTheme.secondaryText)
                }

                Spacer()
            }
        }
        .accessibilityIdentifier("profile.identity")
    }

    private var statsCard: some View {
        AppGlassCard(theme: appModel.appTheme) {
            VStack(spacing: 12) {
                ProfileMetricRow(title: "Memories Seen", value: "\(appModel.profile.memoriesSeenCount)", theme: appModel.appTheme)
                ProfileMetricRow(title: "Saved", value: "\(appModel.librarySaved.count)", theme: appModel.appTheme)
                ProfileMetricRow(title: "Blocked", value: "\(appModel.blockedItems.count)", theme: appModel.appTheme)
                ProfileMetricRow(title: "Theme", value: appModel.selectedTheme.displayName, theme: appModel.appTheme)
                    .accessibilityIdentifier("profile.card.theme")
                ProfileMetricRow(title: "Photo Access", value: photoAccessText, theme: appModel.appTheme)
                    .accessibilityIdentifier("profile.card.photoAccess")
                ProfileMetricRow(title: "Privacy", value: "Local only", theme: appModel.appTheme)
                    .accessibilityIdentifier("profile.card.privacy")
            }
        }
    }

    private var controlsCard: some View {
        AppGlassCard(theme: appModel.appTheme) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Theme")
                    .font(.headline)
                    .foregroundStyle(appModel.appTheme.primaryText)

                ForEach(AppThemes.all, id: \.kind) { option in
                    AppThemeChip(theme: option, isSelected: option.kind == appModel.selectedTheme) {
                        appModel.changeTheme(option.kind)
                    }
                }

                Divider()
                    .overlay(appModel.appTheme.cardStroke)

                Text("Photo Access")
                    .font(.headline)
                    .foregroundStyle(appModel.appTheme.primaryText)

                AppPrimaryButton(
                    title: "Request Photo Access",
                    systemImage: "photo",
                    theme: appModel.appTheme,
                    isEnabled: true
                ) {
                    Task {
                        appModel.authorizationState = await appModel.photoLibrary.requestAuthorization()
                        try? await appModel.refreshLibrary()
                    }
                }
            }
        }
    }

    private var photoAccessText: String {
        switch appModel.authorizationState {
        case .authorized: "Full"
        case .limited: "Limited"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        }
    }
}

private struct ProfileMetricRow: View {
    let title: String
    let value: String
    let theme: AppTheme

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryText)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.cardFill)
        )
    }
}
