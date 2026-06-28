import Foundation
import SwiftData
import Testing
@testable import Memories

struct PhotoLibraryServiceTests {
    @Test
    func excludesScreenshotsAndScreenRecordingsByDefault() async throws {
        let assets = [
            makeDescriptor(id: "photo-1", mediaKind: .photo),
            makeDescriptor(id: "screenshot-1", mediaKind: .photo, isScreenshot: true),
            makeDescriptor(id: "recording-1", mediaKind: .video, isScreenRecording: true)
        ]

        let client = MockPhotoLibraryClient(assets: assets)
        let candidates = try await client.fetchCandidates(filter: .default)

        #expect(candidates.map(\.localIdentifier) == ["photo-1"])
    }

    @Test
    func restoresBlockedStateUsingRecoveryMetadata() async throws {
        let container = try MemoryPersistenceStack.makeContainer(inMemory: true)
        let repository = MemoryRepository(container: container)
        let recoveryKey = MediaRecoveryKey(
            mediaKind: .photo,
            creationDate: Date(timeIntervalSinceReferenceDate: 1000),
            modificationDate: Date(timeIntervalSinceReferenceDate: 2000),
            pixelWidth: 1080,
            pixelHeight: 1920,
            duration: nil,
            burstIdentifier: nil
        )

        try await repository.markBlocked(
            PersistedMediaReference(
                localIdentifier: "old-id",
                status: .blocked,
                recoveryKey: recoveryKey
            )
        )

        let client = MockPhotoLibraryClient(
            assets: [
                makeDescriptor(
                    id: "new-id",
                    mediaKind: .photo,
                    creationDate: recoveryKey.creationDate,
                    modificationDate: recoveryKey.modificationDate,
                    pixelWidth: recoveryKey.pixelWidth,
                    pixelHeight: recoveryKey.pixelHeight
                )
            ],
            stateRepository: repository
        )

        let candidates = try await client.fetchCandidates(filter: .default)
        let blockedReferences = try await repository.blockedReferences()

        #expect(candidates.count == 1)
        #expect(candidates[0].status == .blocked)
        #expect(blockedReferences.first?.localIdentifier == "new-id")
    }

    @Test
    func restorationRejectsAmbiguousMatches() async throws {
        let recoveryKey = MediaRecoveryKey(
            mediaKind: .photo,
            creationDate: Date(timeIntervalSinceReferenceDate: 1000),
            modificationDate: Date(timeIntervalSinceReferenceDate: 2000),
            pixelWidth: 1080,
            pixelHeight: 1920,
            duration: nil,
            burstIdentifier: nil
        )

        let client = MockPhotoLibraryClient(
            assets: [
                makeDescriptor(
                    id: "match-a",
                    mediaKind: .photo,
                    creationDate: recoveryKey.creationDate,
                    modificationDate: recoveryKey.modificationDate,
                    pixelWidth: recoveryKey.pixelWidth,
                    pixelHeight: recoveryKey.pixelHeight
                ),
                makeDescriptor(
                    id: "match-b",
                    mediaKind: .photo,
                    creationDate: recoveryKey.creationDate,
                    modificationDate: recoveryKey.modificationDate,
                    pixelWidth: recoveryKey.pixelWidth,
                    pixelHeight: recoveryKey.pixelHeight
                )
            ]
        )

        let restored = try await client.restoreLocalIdentifier(for: recoveryKey)
        #expect(restored == nil)
    }

    private func makeDescriptor(
        id: String,
        mediaKind: MediaKind,
        creationDate: Date? = Date(timeIntervalSinceReferenceDate: 3000),
        modificationDate: Date? = Date(timeIntervalSinceReferenceDate: 4000),
        pixelWidth: Int = 720,
        pixelHeight: Int = 1280,
        isScreenshot: Bool = false,
        isScreenRecording: Bool = false
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            localIdentifier: id,
            mediaKind: mediaKind,
            creationDate: creationDate,
            modificationDate: modificationDate,
            duration: mediaKind == .video ? 12 : nil,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isFavorite: false,
            isScreenshot: isScreenshot,
            isScreenRecording: isScreenRecording,
            burstIdentifier: nil
        )
    }
}
