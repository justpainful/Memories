import Foundation
import SwiftData
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    var selectedTab: RootTab = .memories
    var hasCompletedOnboarding = false
    var isLoading = true
    var allCandidates: [MemoryCandidate] = []
    var feedCandidates: [MemoryCandidate] = []
    var currentFilter: MemoryFilter = .default
    var selectedTheme: ThemeKind = .nightSky
    var profile: MemoryProfileMetadata = .default
    var authorizationState: PhotoAuthorizationState = .notDetermined
    var cycleIsExhausted = false
    var activeCycleSignature: MemoryCycleSignature?
    var lastErrorMessage: String?
    var focusedCandidateIdentifier: String?

    let sharedModelContainer: ModelContainer
    let photoLibrary: PhotoLibraryClient
    let stateRepository: MemoryStateRepository
    let curationEngine: MemoryCurationEngine
    let sharingClient: MediaSharingClient
    let playbackCoordinator: MemoryPlaybackCoordinator

    private let uiScenario: String?
    private let launchArguments: [String]
    private var observer: PhotoLibraryObserver?
    private let mockCandidates: [MemoryCandidate]

    init() {
        launchArguments = ProcessInfo.processInfo.arguments
        uiScenario = ProcessInfo.processInfo.environment["MEMORIES_UI_TEST_SCENARIO"]
        let useMockData = uiScenario == "onboarding-mock" || uiScenario == "app-mock"

        sharedModelContainer = try! MemoryPersistenceStack.makeContainer(inMemory: useMockData)
        let repository = SwiftDataMemoryStateRepository(container: sharedModelContainer)
        stateRepository = repository

        if useMockData {
            let mockData = Self.makeMockLibrary()
            mockCandidates = mockData.candidates
            photoLibrary = MockPhotoLibraryClient(
                authorization: .limited,
                candidates: mockData.candidates,
                imageData: mockData.imageData,
                videoURLs: mockData.videoURLs
            )
        } else {
            mockCandidates = []
            photoLibrary = PhotoLibraryService()
        }

        curationEngine = MemoryCurationEngine(cycleStore: repository)
        sharingClient = TemporaryMediaSharingClient(photoLibrary: photoLibrary)
        playbackCoordinator = .appCoordinator(photoLibrary: photoLibrary, muteCoordinator: ProcessPlaybackCoordinator.shared)
    }

    var appTheme: AppTheme {
        AppThemes.definition(for: selectedTheme)
    }

    var onboardingDependencies: OnboardingDependencies {
        if uiScenario == "onboarding-mock" {
            return .mock
        }

        return OnboardingDependencies(
            authorizationStatus: { [photoLibrary] in
                await photoLibrary.authorizationStatus()
            },
            requestAuthorization: { [photoLibrary] in
                await photoLibrary.requestAuthorization()
            },
            loadAvatarCandidates: { [weak self] in
                guard let self else { return [] }
                let candidates = try? await self.photoLibrary.fetchCandidates(filter: .default)
                return (candidates ?? []).prefix(8).map { candidate in
                    AvatarCandidate(
                        id: candidate.localIdentifier,
                        assetIdentifier: candidate.localIdentifier,
                        title: candidate.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Library item",
                        detail: candidate.mediaKind.rawValue.capitalized,
                        kind: candidate.mediaKind
                    )
                }
            },
            loadAvatarThumbnail: { [weak self] identifier in
                guard let self else { return nil }
                return try? await self.photoLibrary.fetchImageData(localIdentifier: identifier, targetSize: CGSize(width: 240, height: 240))
            }
        )
    }

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }

        do {
            if uiScenario == "onboarding-mock" || uiScenario == "app-mock" {
                try await seedMockStateIfNeeded()
            }

            let snapshot = try await stateRepository.loadSnapshot()
            profile = snapshot.profile
            selectedTheme = profile.selectedTheme
            if uiScenario == "app-mock" {
                hasCompletedOnboarding = true
                if profile.displayName.isEmpty {
                    profile.displayName = "Ava"
                    profile.fallbackInitials = "A"
                    selectedTheme = .reflectiveDark
                    profile.selectedTheme = .reflectiveDark
                    try? await stateRepository.saveProfileMetadata(profile)
                }
            } else {
                hasCompletedOnboarding = !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && uiScenario != "onboarding-mock"
            }
            authorizationState = await photoLibrary.authorizationStatus()
            try await refreshLibrary()

            if launchArguments.contains("UITestsSkipOnboarding") {
                hasCompletedOnboarding = true
            }

            if launchArguments.contains("UITestsStartLibrary") {
                selectedTab = .library
            } else if launchArguments.contains("UITestsStartBlocked") {
                selectedTab = .blocked
            } else if launchArguments.contains("UITestsStartProfile") {
                selectedTab = .profile
            }

            if let nameIndex = launchArguments.firstIndex(of: "UITestsProfileName"),
               launchArguments.indices.contains(nameIndex + 1) {
                profile.displayName = launchArguments[nameIndex + 1]
                profile.fallbackInitials = String(profile.displayName.prefix(1)).uppercased()
            }

            if observer == nil, uiScenario != "onboarding-mock", uiScenario != "app-mock" {
                observer = PhotoLibraryObserver { [weak self] in
                    guard let self else { return }
                    Task { await self.handlePhotoLibraryChange() }
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshLibrary() async throws {
        authorizationState = await photoLibrary.authorizationStatus()

        let baseCandidates: [MemoryCandidate]
        if uiScenario == "onboarding-mock" {
            baseCandidates = mockCandidates
        } else {
            baseCandidates = try await photoLibrary.fetchCandidates(filter: .default)
        }

        let saved = try await stateRepository.savedReferences()
        let blocked = try await stateRepository.blockedReferences()
        let savedSet = Set(saved.map(\.localIdentifier))
        let blockedSet = Set(blocked.map(\.localIdentifier))

        allCandidates = baseCandidates.map { candidate in
            var updated = candidate
            if blockedSet.contains(candidate.localIdentifier) {
                updated.status = .blocked
            } else if savedSet.contains(candidate.localIdentifier) {
                updated.status = .saved
            } else {
                updated.status = .eligible
            }
            return updated
        }

        try await refreshFeed()
    }

    func refreshFeed() async throws {
        let filtered = allCandidates.filter(matchesCurrentFilter)
        let cycle = try await curationEngine.curateCycle(from: filtered, filter: currentFilter)
        var ordered = cycle.orderedCandidates
        if let focusedCandidateIdentifier,
           let index = ordered.firstIndex(where: { $0.localIdentifier == focusedCandidateIdentifier }) {
            let candidate = ordered.remove(at: index)
            ordered.insert(candidate, at: 0)
            self.focusedCandidateIdentifier = nil
        }
        feedCandidates = ordered
        activeCycleSignature = cycle.signature
        cycleIsExhausted = cycle.exhausted
    }

    func updateFilter(_ filter: MemoryFilter) {
        currentFilter = filter
        Task {
            try? await refreshFeed()
        }
    }

    func startNewCycle() {
        Task {
            try? await curationEngine.resetCycle(for: currentFilter)
            try? await refreshFeed()
        }
    }

    func markSeen(_ candidate: MemoryCandidate) {
        guard let signature = activeCycleSignature else { return }
        Task {
            try? await curationEngine.recordViewed(candidate, signature: signature)
            profile.memoriesSeenCount += 1
            profile.lastPresentedIdentifier = candidate.localIdentifier
            profile.lastCurationDate = .now
            try? await stateRepository.saveProfileMetadata(profile)
        }
    }

    func toggleSaved(_ candidate: MemoryCandidate) {
        Task {
            let reference = PersistedMediaReference(
                localIdentifier: candidate.localIdentifier,
                status: .saved,
                recoveryKey: candidate.recoveryKey,
                updatedAt: .now
            )

            if candidate.status == .saved {
                try? await stateRepository.removeSaved(localIdentifier: candidate.localIdentifier)
            } else {
                try? await stateRepository.markSaved(reference)
                if candidate.status == .blocked {
                    try? await stateRepository.removeBlocked(localIdentifier: candidate.localIdentifier)
                }
            }

            try? await refreshLibrary()
        }
    }

    func block(_ candidate: MemoryCandidate) {
        Task {
            let reference = PersistedMediaReference(
                localIdentifier: candidate.localIdentifier,
                status: .blocked,
                recoveryKey: candidate.recoveryKey,
                updatedAt: .now
            )
            try? await stateRepository.markBlocked(reference)
            try? await stateRepository.removeSaved(localIdentifier: candidate.localIdentifier)
            try? await refreshLibrary()
        }
    }

    func unblock(_ candidate: MemoryCandidate) {
        Task {
            try? await stateRepository.removeBlocked(localIdentifier: candidate.localIdentifier)
            try? await refreshLibrary()
        }
    }

    func applyOnboardingCompletion(from store: OnboardingStore) {
        profile.displayName = store.draft.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.selectedTheme = store.draft.selectedTheme
        profile.avatarLocalIdentifier = store.draft.selectedAvatarID
        profile.fallbackInitials = String(profile.displayName.prefix(1)).uppercased().isEmpty ? "M" : String(profile.displayName.prefix(1)).uppercased()
        selectedTheme = store.draft.selectedTheme
        authorizationState = store.draft.permissionState
        hasCompletedOnboarding = true

        Task {
            try? await stateRepository.saveProfileMetadata(profile)
            try? await refreshLibrary()
        }
    }

    func changeTheme(_ theme: ThemeKind) {
        selectedTheme = theme
        profile.selectedTheme = theme
        Task {
            try? await stateRepository.saveProfileMetadata(profile)
        }
    }

    func changeProfileName(_ name: String) {
        profile.displayName = name
        profile.fallbackInitials = String(name.prefix(1)).uppercased().isEmpty ? "M" : String(name.prefix(1)).uppercased()
        Task {
            try? await stateRepository.saveProfileMetadata(profile)
        }
    }

    var libraryAll: [MemoryCandidate] {
        allCandidates.filter { $0.status != .blocked }
    }

    var libraryPhotos: [MemoryCandidate] {
        libraryAll.filter { $0.mediaKind == .photo || $0.mediaKind == .livePhoto }
    }

    var libraryVideos: [MemoryCandidate] {
        libraryAll.filter { $0.mediaKind == .video }
    }

    var librarySaved: [MemoryCandidate] {
        libraryAll.filter { $0.status == .saved }
    }

    var blockedItems: [MemoryCandidate] {
        allCandidates.filter { $0.status == .blocked }
    }

    func openCandidate(_ candidate: MemoryCandidate) {
        focusedCandidateIdentifier = candidate.localIdentifier
        selectedTab = .memories
        var filter = currentFilter
        filter.mediaKinds = [candidate.mediaKind]
        updateFilter(filter)
    }

    private func handlePhotoLibraryChange() async {
        try? await refreshLibrary()
    }

    private func seedMockStateIfNeeded() async throws {
        let saved = try await stateRepository.savedReferences()
        let blocked = try await stateRepository.blockedReferences()
        guard saved.isEmpty, blocked.isEmpty else { return }

        let mockStatusMap: [String: MemoryStatus] = [
            "memory-001": .saved,
            "memory-003": .blocked,
            "memory-005": .saved,
            "memory-006": .blocked
        ]

        for candidate in mockCandidates {
            guard let status = mockStatusMap[candidate.localIdentifier] else { continue }
            let reference = PersistedMediaReference(
                localIdentifier: candidate.localIdentifier,
                status: status,
                recoveryKey: candidate.recoveryKey,
                updatedAt: .now
            )
            switch status {
            case .saved:
                try await stateRepository.markSaved(reference)
            case .blocked:
                try await stateRepository.markBlocked(reference)
            case .eligible, .missing:
                break
            }
        }
    }

    private func matchesCurrentFilter(_ candidate: MemoryCandidate) -> Bool {
        guard currentFilter.mediaKinds.contains(candidate.mediaKind) else { return false }
        guard currentFilter.includesScreenshots || !candidate.isScreenshot else { return false }
        guard currentFilter.includesScreenRecordings || !candidate.isScreenRecording else { return false }

        guard let creationDate = candidate.creationDate else { return true }
        let year = Calendar.current.component(.year, from: creationDate)
        if let lower = currentFilter.yearFrom, year < lower { return false }
        if let upper = currentFilter.yearTo, year > upper { return false }
        return true
    }

    private static func makeMockLibrary() -> (candidates: [MemoryCandidate], imageData: [String: Data], videoURLs: [String: URL]) {
        let ids = ["memory-001", "memory-002", "memory-003", "memory-004", "memory-005", "memory-006"]
        let colors: [UIColor] = [.systemBlue, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        var candidates: [MemoryCandidate] = []
        var imageData: [String: Data] = [:]

        for (index, id) in ids.enumerated() {
            let kind: MediaKind = switch id {
            case "memory-002", "memory-005":
                .video
            case "memory-003":
                .livePhoto
            default:
                .photo
            }
            let date = Calendar.current.date(byAdding: .day, value: -(index * 23), to: .now)
            let candidate = MemoryCandidate(
                localIdentifier: id,
                mediaKind: kind,
                creationDate: date,
                modificationDate: date,
                duration: kind == .video ? 12 : nil,
                pixelWidth: 1284,
                pixelHeight: 2778,
                isFavorite: index % 2 == 0,
                isScreenshot: false,
                isScreenRecording: false,
                burstIdentifier: id == "memory-003" ? "burst-1" : nil,
                status: .eligible,
                recoveryKey: MediaRecoveryKey(
                    mediaKind: kind,
                    creationDate: date,
                    modificationDate: date,
                    pixelWidth: 1284,
                    pixelHeight: 2778,
                    duration: kind == .video ? 12 : nil,
                    burstIdentifier: id == "memory-003" ? "burst-1" : nil
                )
            )
            candidates.append(candidate)
            imageData[id] = makeMockImageData(color: colors[index % colors.count], title: "\(index + 1)")
        }

        return (candidates, imageData, [:])
    }

    private static func makeMockImageData(color: UIColor, title: String) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 180, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            NSString(string: title).draw(in: CGRect(x: 0, y: 330, width: 600, height: 220), withAttributes: attributes)
        }

        return image.jpegData(compressionQuality: 0.92)
    }
}

enum RootTab: String, CaseIterable, Identifiable {
    case memories
    case library
    case blocked
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memories: "Memories"
        case .library: "Library"
        case .blocked: "Blocked"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .memories: "sparkles"
        case .library: "rectangle.stack"
        case .blocked: "eye.slash"
        case .profile: "person.crop.square"
        }
    }
}
