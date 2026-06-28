import SwiftUI
import UIKit

struct OnboardingAvatarPickerView: View {
    let store: OnboardingStore
    let theme: AppTheme

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose an avatar")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.primaryText)

            Text("This is a custom PhotoKit shell for onboarding. It previews a few library items without using the system photo picker.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)

            LazyVGrid(columns: columns, spacing: 14) {
                defaultMonogramTile

                ForEach(store.avatarCandidates) { candidate in
                    avatarTile(for: candidate)
                }
            }
        }
    }

    private var defaultMonogramTile: some View {
        Button {
            store.chooseAvatar(nil)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(theme.secondaryAccent.opacity(0.22))
                    Text(monogram)
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }
                .frame(height: 132)

                Text("Default monogram")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)

                Text("No photo selected yet")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tileBackground(isSelected: store.draft.selectedAvatarID == nil))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.avatar.default")
    }

    private func avatarTile(for candidate: AvatarCandidate) -> some View {
        let selected = store.draft.selectedAvatarID == candidate.assetIdentifier

        return Button {
            store.chooseAvatar(candidate)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    thumbnail(for: candidate)
                        .frame(height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? theme.accent : theme.primaryText.opacity(0.82))
                        .padding(10)
                }

                Text(candidate.title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)

                Text(candidate.detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tileBackground(isSelected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.avatar.\(candidate.assetIdentifier)")
    }

    @ViewBuilder
    private func thumbnail(for candidate: AvatarCandidate) -> some View {
        if let data = store.thumbnails[candidate.assetIdentifier]?.imageData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [theme.accent.opacity(0.6), theme.secondaryAccent.opacity(0.4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: iconName(for: candidate.kind))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            }
        }
    }

    @ViewBuilder
    private func tileBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(theme.cardFill)
            .glassEffect(
                .regular
                    .tint((isSelected ? theme.accent : theme.glassTint).opacity(isSelected ? 0.30 : 0.18))
                    .interactive(),
                in: .rect(cornerRadius: 26)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(isSelected ? theme.accent.opacity(0.72) : theme.cardStroke, lineWidth: 1)
            }
    }

    private var monogram: String {
        let trimmed = store.draft.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased().isEmpty ? "M" : String(trimmed.prefix(1)).uppercased()
    }

    private func iconName(for kind: MediaKind) -> String {
        switch kind {
        case .photo:
            "photo"
        case .video:
            "video"
        case .livePhoto:
            "livephoto"
        }
    }
}
