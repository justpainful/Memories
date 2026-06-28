import SwiftUI

struct OnboardingFlowView: View {
    @State private var store: OnboardingStore
    @FocusState private var nameFieldFocused: Bool

    init(store: OnboardingStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        let theme = store.theme

        ZStack {
            AppBackgroundView(theme: theme)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {
                    progressHeader(theme: theme)
                        .motionEntrance(active: true)

                    stepContent(theme: theme)
                        .id(store.currentStep)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))

                    footer(theme: theme)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
        }
        .task {
            await store.bootstrap()
        }
        .appTheme(theme)
    }

    private func progressHeader(theme: AppTheme) -> some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(store.currentStep.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("\(store.currentStep.rawValue + 1)/\(OnboardingStep.allCases.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("onboarding.progress.value")
                }

                ProgressView(value: store.progressValue)
                    .tint(theme.accent)
                    .accessibilityIdentifier("onboarding.progress.bar")

                Text(store.currentStep.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .accessibilityIdentifier("onboarding.header")
    }

    @ViewBuilder
    private func stepContent(theme: AppTheme) -> some View {
        switch store.currentStep {
        case .reveal:
            OnboardingRevealStep(theme: theme, isReady: store.canContinueFromReveal)
                .accessibilityIdentifier("onboarding.step.reveal")
        case .profile:
            profileStep(theme: theme)
                .accessibilityIdentifier("onboarding.step.profile")
        case .privacy:
            privacyStep(theme: theme)
                .accessibilityIdentifier("onboarding.step.privacy")
        case .permission:
            permissionStep(theme: theme)
                .accessibilityIdentifier("onboarding.step.permission")
        case .theme:
            themeStep(theme: theme)
                .accessibilityIdentifier("onboarding.step.theme")
        case .avatar:
            avatarStep(theme: theme)
                .accessibilityIdentifier("onboarding.step.avatar")
        case .finish:
            finishStep(theme: theme)
                .accessibilityIdentifier("onboarding.step.finish")
        }
    }

    private func footer(theme: AppTheme) -> some View {
        VStack(spacing: 14) {
            if store.currentStep != .reveal {
                AppSecondaryButton(title: "Back", theme: theme) {
                    store.back()
                }
                .accessibilityIdentifier("onboarding.back")
            }

            if store.currentStep == .permission &&
                (store.draft.permissionState == .denied || store.draft.permissionState == .restricted) {
                Text("Open Settings to change access if you want avatar suggestions and the memory feed to work.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppPrimaryButton(
                title: store.currentStep == .finish ? "Enter Memories" : "Continue",
                systemImage: store.currentStep == .finish ? "arrow.right.circle.fill" : "arrow.right",
                theme: theme,
                isEnabled: store.canAdvance(from: store.currentStep)
            ) {
                store.next()
            }
            .accessibilityIdentifier("onboarding.continue")
        }
    }

    private func profileStep(theme: AppTheme) -> some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 20) {
                Text("How should Memories address you?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                TextField("First name", text: nameBinding)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($nameFieldFocused)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .background(textFieldBackground(theme: theme))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityIdentifier("onboarding.name")

                Text("This stays on-device and is only used for personal copy in the app.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .onAppear {
            nameFieldFocused = true
        }
    }

    private func privacyStep(theme: AppTheme) -> some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Local-first means your photo library remains the source of truth.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                AppGlassGroup(spacing: 14) {
                    VStack(spacing: 14) {
                        privacyBullet(
                            title: "No duplicate library",
                            detail: "Memories reads PhotoKit references and leaves the original media in Apple Photos.",
                            icon: "photo.on.rectangle.angled",
                            theme: theme
                        )

                        privacyBullet(
                            title: "No cloud profile",
                            detail: "Your name, selected theme, avatar choice, and viewing history stay on this iPhone.",
                            icon: "lock.shield",
                            theme: theme
                        )

                        privacyBullet(
                            title: "Sharing is explicit",
                            detail: "Temporary exports are created only when you choose to share a memory.",
                            icon: "square.and.arrow.up",
                            theme: theme
                        )
                    }
                }
            }
        }
    }

    private func permissionStep(theme: AppTheme) -> some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Grant access to surface memories from your photo library.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                HStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.title2)
                        .foregroundStyle(theme.accent)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.permissionSummaryText())
                            .font(.headline)
                            .foregroundStyle(theme.primaryText)
                            .accessibilityIdentifier("onboarding.permission.status")
                        Text("Memories supports full or limited access in Phase 1.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                AppPrimaryButton(
                    title: store.isRequestingPermissions ? "Requesting..." : "Allow Photo Access",
                    systemImage: "hand.raised.circle",
                    theme: theme,
                    isEnabled: !store.isRequestingPermissions
                ) {
                    Task { await store.requestPermissions() }
                }
                .accessibilityIdentifier("onboarding.permission.request")

                if store.draft.permissionState == .limited {
                    Text("Limited access works now. You can expand selection later in Photos privacy settings.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private func themeStep(theme: AppTheme) -> some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Switch themes before you enter the feed.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                ForEach(AppThemes.all, id: \.kind) { option in
                    AppThemeChip(
                        theme: option,
                        isSelected: store.draft.selectedTheme == option.kind
                    ) {
                        store.selectTheme(option.kind)
                    }
                    .accessibilityIdentifier("onboarding.theme.\(option.kind.rawValue)")
                }
            }
        }
    }

    private func avatarStep(theme: AppTheme) -> some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Avatar suggestions come from your existing photo library.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                if store.avatarCandidates.isEmpty {
                    Text("No mock avatar suggestions are loaded yet. You can continue with the monogram and choose a photo later.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    OnboardingAvatarPickerView(store: store, theme: theme)
                }
            }
        }
    }

    private func finishStep(theme: AppTheme) -> some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Memories is ready with your local setup.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                summaryRow(title: "Name", value: store.draft.firstName, theme: theme)
                summaryRow(title: "Theme", value: store.draft.selectedTheme.displayName, theme: theme)
                summaryRow(title: "Photo Access", value: store.permissionSummaryText(), theme: theme)
                summaryRow(title: "Avatar", value: store.avatarSelection?.title ?? "Default monogram", theme: theme)
            }
        }
    }

    private func privacyBullet(
        title: String,
        detail: String,
        icon: String,
        theme: AppTheme
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(theme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(textFieldBackground(theme: theme))
    }

    private func summaryRow(title: String, value: String, theme: AppTheme) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(theme.primaryText)
        }
    }

    @ViewBuilder
    private func textFieldBackground(theme: AppTheme) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(theme.cardFill)
            .glassEffect(.regular.tint(theme.glassTint.opacity(0.16)), in: .rect(cornerRadius: 22))
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { store.draft.firstName },
            set: { store.setName($0) }
        )
    }
}

private struct OnboardingRevealStep: View {
    let theme: AppTheme
    let isReady: Bool
    @State private var glowExpanded = false

    var body: some View {
        AppGlassCard(theme: theme) {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(theme.halo.opacity(glowExpanded ? 0.95 : 0.52))
                        .frame(width: glowExpanded ? 180 : 136, height: glowExpanded ? 180 : 136)
                        .blur(radius: 22)

                    AppGlassGroup(spacing: 18) {
                        HStack(spacing: 18) {
                            revealOrb(icon: "sparkles")
                            revealOrb(icon: "livephoto")
                            revealOrb(icon: "moon.stars.fill")
                        }
                    }
                }
                .frame(height: 180)

                VStack(spacing: 10) {
                    Text("Memories")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("A local-first ritual for revisiting photos, videos, and Live Photos already on your iPhone.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .motionEntrance(active: isReady, offset: 30, opacity: 0.2)
        .task {
            withAnimation(AppMotion.reveal.repeatCount(1, autoreverses: false)) {
                glowExpanded = true
            }
        }
    }

    private func revealOrb(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .frame(width: 76, height: 76)
            .background(orbBackground)
    }

    @ViewBuilder
    private var orbBackground: some View {
        Circle()
            .fill(theme.cardFill)
            .glassEffect(
                .regular
                    .tint(theme.glassTint.opacity(0.26))
                    .interactive(),
                in: .circle
            )
    }
}

#Preview("Onboarding Mock") {
    OnboardingFlowView(store: OnboardingMockFactory.makeStore())
}

typealias OnboardingView = OnboardingFlowView
