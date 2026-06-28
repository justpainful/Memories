import Foundation
import Observation

@MainActor
@Observable
final class OnboardingStore {
    var draft = OnboardingDraft()
    var currentStep: OnboardingStep = .reveal
    var avatarCandidates: [AvatarCandidate] = []
    var thumbnails: [String: AvatarThumbnail] = [:]
    var hasRequestedPermissions = false
    var isRequestingPermissions = false
    var canContinueFromReveal = false
    var didComplete = false

    private let dependencies: OnboardingDependencies
    private let haptics: AppHaptics

    init(
        dependencies: OnboardingDependencies,
        haptics: AppHaptics = .live
    ) {
        self.dependencies = dependencies
        self.haptics = haptics
    }

    var theme: AppTheme {
        AppThemes.definition(for: draft.selectedTheme)
    }

    var progressValue: Double {
        Double(currentStep.rawValue + 1) / Double(OnboardingStep.allCases.count)
    }

    var avatarSelection: AvatarCandidate? {
        avatarCandidates.first { $0.assetIdentifier == draft.selectedAvatarID }
    }

    func bootstrap() async {
        draft.permissionState = await dependencies.authorizationStatus()
        await loadAvatarCandidatesIfNeeded()

        try? await Task.sleep(for: .milliseconds(280))
        withAnimation(MemoriesMotion.reveal) {
            canContinueFromReveal = true
        }
    }

    func selectTheme(_ themeKind: ThemeKind) {
        draft.selectedTheme = themeKind
        haptics.selection()
    }

    func setName(_ value: String) {
        draft.firstName = String(value.prefix(24))
    }

    func requestPermissions() async {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true

        let state = await dependencies.requestAuthorization()
        draft.permissionState = state
        hasRequestedPermissions = true
        isRequestingPermissions = false

        switch state {
        case .authorized, .limited:
            haptics.success()
            await loadAvatarCandidatesIfNeeded(force: true)
        case .denied, .restricted:
            haptics.warning()
        case .notDetermined:
            break
        }
    }

    func chooseAvatar(_ candidate: AvatarCandidate?) {
        draft.selectedAvatarID = candidate?.assetIdentifier
        haptics.selection()
    }

    func next() {
        guard let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) else {
            didComplete = true
            haptics.success()
            return
        }

        withAnimation(MemoriesMotion.card) {
            currentStep = nextStep
        }
        haptics.selection()
    }

    func back() {
        guard let previousStep = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        withAnimation(MemoriesMotion.card) {
            currentStep = previousStep
        }
        haptics.selection()
    }

    func canAdvance(from step: OnboardingStep) -> Bool {
        switch step {
        case .reveal:
            canContinueFromReveal
        case .profile:
            !draft.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .privacy:
            true
        case .permission:
            draft.permissionState == .authorized || draft.permissionState == .limited
        case .theme:
            true
        case .avatar:
            true
        case .finish:
            true
        }
    }

    func permissionSummaryText() -> String {
        switch draft.permissionState {
        case .notDetermined:
            "Not requested yet"
        case .authorized:
            "Full library access granted"
        case .limited:
            "Limited library access granted"
        case .denied:
            "Access denied in system privacy settings"
        case .restricted:
            "Access restricted on this device"
        }
    }

    private func loadAvatarCandidatesIfNeeded(force: Bool = false) async {
        guard force || avatarCandidates.isEmpty else { return }
        avatarCandidates = await dependencies.loadAvatarCandidates()

        for candidate in avatarCandidates.prefix(12) {
            let data = await dependencies.loadAvatarThumbnail(candidate.assetIdentifier)
            thumbnails[candidate.assetIdentifier] = AvatarThumbnail(
                assetIdentifier: candidate.assetIdentifier,
                imageData: data
            )
        }
    }
}
