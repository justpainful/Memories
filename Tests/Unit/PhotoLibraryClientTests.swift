import XCTest
@testable import Memories

final class PhotoLibraryClientTests: XCTestCase {
    func testMockPhotoLibraryExcludesScreenshotsByDefault() async throws {
        let visible = makeCandidate(id: "visible", screenshot: false, recording: false)
        let screenshot = makeCandidate(id: "screenshot", screenshot: true, recording: false)
        let client = MockPhotoLibraryClient(candidates: [visible, screenshot])

        let results = try await client.fetchCandidates(filter: .default)

        XCTAssertEqual(results.map(\.localIdentifier), ["visible"])
    }

    func testMockPhotoLibraryCanIncludeScreenRecordingsWhenRequested() async throws {
        let recording = makeCandidate(id: "recording", screenshot: false, recording: true, kind: .video)
        let client = MockPhotoLibraryClient(candidates: [recording])
        let filter = MemoryFilter(
            preset: nil,
            yearFrom: nil,
            yearTo: nil,
            mediaKinds: [.video],
            selectionMode: .smartRandom,
            includesScreenshots: false,
            includesScreenRecordings: true
        )

        let results = try await client.fetchCandidates(filter: filter)

        XCTAssertEqual(results.map(\.localIdentifier), ["recording"])
    }

    private func makeCandidate(id: String, screenshot: Bool, recording: Bool, kind: MediaKind = .photo) -> MemoryCandidate {
        MemoryCandidate(
            localIdentifier: id,
            mediaKind: kind,
            creationDate: .now,
            modificationDate: .now,
            duration: kind == .video ? 4 : nil,
            pixelWidth: 1200,
            pixelHeight: 900,
            isFavorite: false,
            isScreenshot: screenshot,
            isScreenRecording: recording,
            burstIdentifier: nil,
            status: .eligible,
            recoveryKey: MediaRecoveryKey(
                mediaKind: kind,
                creationDate: .now,
                modificationDate: .now,
                pixelWidth: 1200,
                pixelHeight: 900,
                duration: kind == .video ? 4 : nil,
                burstIdentifier: nil
            )
        )
    }
}
