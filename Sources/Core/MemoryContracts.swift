import CoreGraphics
import Foundation
import Photos
import PhotosUI

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case livePhoto
}

enum MemoryStatus: String, Codable, Sendable {
    case eligible
    case saved
    case blocked
    case missing
}

enum SelectionMode: String, Codable, CaseIterable, Sendable {
    case smartRandom
    case pureRandom
}

enum ThemeKind: String, Codable, CaseIterable, Sendable {
    case nightSky
    case reflectiveDark
}

enum MemoryExplorePreset: String, Codable, CaseIterable, Sendable {
    case thisWeekAcrossYears
    case previousWeekAcrossYears
    case nextWeekAcrossYears
    case onThisDay
    case randomFromEntireLibrary
}

struct MemoryFilter: Hashable, Codable, Sendable {
    var preset: MemoryExplorePreset?
    var yearFrom: Int?
    var yearTo: Int?
    var mediaKinds: Set<MediaKind>
    var selectionMode: SelectionMode
    var includesScreenshots: Bool
    var includesScreenRecordings: Bool

    static let `default` = MemoryFilter(
        preset: nil,
        yearFrom: nil,
        yearTo: nil,
        mediaKinds: Set(MediaKind.allCases),
        selectionMode: .smartRandom,
        includesScreenshots: false,
        includesScreenRecordings: false
    )
}

struct MemoryCycleSignature: Hashable, Codable, Sendable {
    var rawValue: String

    init(filter: MemoryFilter) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(filter)) ?? Data()
        rawValue = data.base64EncodedString()
    }
}

struct MediaRecoveryKey: Hashable, Codable, Sendable {
    var mediaKind: MediaKind
    var creationDate: Date?
    var modificationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: TimeInterval?
    var burstIdentifier: String?
}

struct MemoryCandidate: Identifiable, Hashable, Sendable {
    var id: String { localIdentifier }
    var localIdentifier: String
    var mediaKind: MediaKind
    var creationDate: Date?
    var modificationDate: Date?
    var duration: TimeInterval?
    var pixelWidth: Int
    var pixelHeight: Int
    var isFavorite: Bool
    var isScreenshot: Bool
    var isScreenRecording: Bool
    var burstIdentifier: String?
    var status: MemoryStatus
    var recoveryKey: MediaRecoveryKey
}

enum PhotoAuthorizationState: String, Codable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
}

protocol PhotoLibraryClient: Sendable {
    func authorizationStatus() async -> PhotoAuthorizationState
    func requestAuthorization() async -> PhotoAuthorizationState
    func fetchCandidates(filter: MemoryFilter) async throws -> [MemoryCandidate]
    func restoreLocalIdentifier(for recoveryKey: MediaRecoveryKey) async throws -> String?
    func fetchAsset(localIdentifier: String) async -> PHAsset?
    func fetchImageData(localIdentifier: String, targetSize: CGSize?) async throws -> Data?
    func fetchVideoURL(localIdentifier: String) async throws -> URL?
    func fetchLivePhoto(localIdentifier: String, targetSize: CGSize) async throws -> PHLivePhoto?
}

protocol MemoryCurationScoring: Sendable {
    func score(candidate: MemoryCandidate, context: MemoryScoringContext) -> Double
}

struct MemoryScoringContext: Sendable {
    var currentDate: Date
    var recentlyViewedIdentifiers: Set<String>
    var previousCandidate: MemoryCandidate?
}

protocol MemoryCycleStore: Sendable {
    func viewedIdentifiers(for signature: MemoryCycleSignature) async throws -> [String]
    func recordViewed(identifier: String, signature: MemoryCycleSignature) async throws
    func resetCycle(for signature: MemoryCycleSignature) async throws
}

struct PersistedMediaReference: Identifiable, Hashable, Codable, Sendable {
    var id: String { localIdentifier }
    var localIdentifier: String
    var status: MemoryStatus
    var recoveryKey: MediaRecoveryKey
    var updatedAt: Date

    init(
        localIdentifier: String,
        status: MemoryStatus,
        recoveryKey: MediaRecoveryKey,
        updatedAt: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.status = status
        self.recoveryKey = recoveryKey
        self.updatedAt = updatedAt
    }
}

struct MemoryProfileMetadata: Hashable, Codable, Sendable {
    var displayName: String
    var selectedTheme: ThemeKind
    var lastPresentedIdentifier: String?
    var lastCurationDate: Date?
    var launchCount: Int
    var memoriesSeenCount: Int
    var avatarLocalIdentifier: String?
    var avatarCropRect: CGRect?
    var fallbackInitials: String

    static let `default` = MemoryProfileMetadata(
        displayName: "",
        selectedTheme: .nightSky,
        lastPresentedIdentifier: nil,
        lastCurationDate: nil,
        launchCount: 0,
        memoriesSeenCount: 0,
        avatarLocalIdentifier: nil,
        avatarCropRect: nil,
        fallbackInitials: "M"
    )
}

struct MemoryStateSnapshot: Hashable, Sendable {
    var savedReferences: [PersistedMediaReference]
    var blockedReferences: [PersistedMediaReference]
    var profile: MemoryProfileMetadata

    static let empty = MemoryStateSnapshot(
        savedReferences: [],
        blockedReferences: [],
        profile: .default
    )
}

protocol MemoryStateRepository: MemoryCycleStore, Sendable {
    func loadSnapshot() async throws -> MemoryStateSnapshot
    func savedReferences() async throws -> [PersistedMediaReference]
    func blockedReferences() async throws -> [PersistedMediaReference]
    func markSaved(_ reference: PersistedMediaReference) async throws
    func markBlocked(_ reference: PersistedMediaReference) async throws
    func removeSaved(localIdentifier: String) async throws
    func removeBlocked(localIdentifier: String) async throws
    func loadProfileMetadata() async throws -> MemoryProfileMetadata
    func saveProfileMetadata(_ metadata: MemoryProfileMetadata) async throws
    func persistedReference(matching recoveryKey: MediaRecoveryKey, status: MemoryStatus) async throws -> PersistedMediaReference?
}

protocol MediaSharingClient: Sendable {
    func prepareShareURL(for candidate: MemoryCandidate) async throws -> URL
    func cleanupExpiredTemporaryFiles() async
}

protocol PlaybackCoordinating: Sendable {
    var isMuted: Bool { get async }
    func setMuted(_ muted: Bool) async
}

protocol PhotoLibraryObserving: Sendable {
    func changes() -> AsyncStream<Void>
}
