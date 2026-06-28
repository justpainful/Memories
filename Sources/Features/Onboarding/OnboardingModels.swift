import Foundation
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case reveal
    case profile
    case privacy
    case permission
    case theme
    case avatar
    case finish

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .reveal:
            "Memories"
        case .profile:
            "Make it yours"
        case .privacy:
            "Private by design"
        case .permission:
            "Photo access"
        case .theme:
            "Choose a theme"
        case .avatar:
            "Pick an avatar"
        case .finish:
            "Ready to begin"
        }
    }

    var subtitle: String {
        switch self {
        case .reveal:
            "Resurface photos, videos, and Live Photos already in Apple Photos."
        case .profile:
            "Your name and avatar stay local to this iPhone."
        case .privacy:
            "Nothing leaves the device unless you intentionally share a memory."
        case .permission:
            "Memories needs library access to discover moments worth revisiting."
        case .theme:
            "Night Sky and Reflective Dark both support the Phase 1 experience."
        case .avatar:
            "Choose a library image now or keep the default monogram for later."
        case .finish:
            "You can refine filters, blocked items, and profile details after onboarding."
        }
    }
}

struct OnboardingDraft: Sendable {
    var firstName: String = ""
    var selectedTheme: ThemeKind = .nightSky
    var permissionState: PhotoAuthorizationState = .notDetermined
    var selectedAvatarID: String?
}

struct AvatarCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let assetIdentifier: String
    let title: String
    let detail: String
    let kind: MediaKind
}

struct AvatarThumbnail: Hashable, Sendable {
    let assetIdentifier: String
    let imageData: Data?
}

struct OnboardingDependencies: Sendable {
    var authorizationStatus: @Sendable () async -> PhotoAuthorizationState
    var requestAuthorization: @Sendable () async -> PhotoAuthorizationState
    var loadAvatarCandidates: @Sendable () async -> [AvatarCandidate]
    var loadAvatarThumbnail: @Sendable (String) async -> Data?
}

extension OnboardingDependencies {
    static let placeholder = OnboardingDependencies(
        authorizationStatus: { .notDetermined },
        requestAuthorization: { .authorized },
        loadAvatarCandidates: { [] },
        loadAvatarThumbnail: { _ in nil }
    )
}
