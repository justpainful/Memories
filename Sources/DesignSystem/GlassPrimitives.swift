import SwiftUI

struct AppGlassCard<Content: View>: View {
    let theme: AppTheme
    let content: Content

    init(
        theme: AppTheme,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(cardStroke)
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    @ViewBuilder
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(theme.cardFill)
            .glassEffect(
                .regular
                    .tint(theme.glassTint.opacity(0.26)),
                in: .rect(cornerRadius: 30)
            )
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .stroke(theme.cardStroke, lineWidth: 1)
    }
}

struct AppGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(
        spacing: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

struct AppThemeChip: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.secondaryAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 20, height: 20)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.name)
                        .font(.headline)
                    Text(theme.summary)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .foregroundStyle(theme.primaryText)
            .background(background)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        isSelected ? theme.accent.opacity(0.70) : theme.cardStroke,
                        lineWidth: isSelected ? 1.4 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(theme.cardFill)
            .glassEffect(
                .regular
                    .tint((isSelected ? theme.accent : theme.glassTint).opacity(isSelected ? 0.26 : 0.18))
                    .interactive(),
                in: .rect(cornerRadius: 22)
            )
    }
}

struct AppPrimaryButton: View {
    let title: String
    let systemImage: String?
    let theme: AppTheme
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .disabled(!isEnabled)
        .modifier(AppGlassButtonModifier(theme: theme, prominent: true))
    }
}

struct AppSecondaryButton: View {
    let title: String
    let theme: AppTheme
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .modifier(AppGlassButtonModifier(theme: theme, prominent: false))
    }
}

private struct AppGlassButtonModifier: ViewModifier {
    let theme: AppTheme
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if prominent {
            content
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .foregroundStyle(theme.primaryText)
        } else {
            content
                .buttonStyle(.glass)
                .tint(theme.glassTint)
                .foregroundStyle(theme.primaryText)
        }
    }
}

typealias MemoriesGlassCard = AppGlassCard
typealias MemoriesGlassGroup = AppGlassGroup
typealias MemoriesThemeChip = AppThemeChip
typealias MemoriesPrimaryButton = AppPrimaryButton
typealias MemoriesSecondaryButton = AppSecondaryButton
