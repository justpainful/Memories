import SwiftUI
import UIKit
import XCTest
@testable import Memories

@MainActor
final class PlaybackPreloadCoordinatorTests: XCTestCase {
    func testActivatePreloadsCurrentPreviousAndNextOnly() async {
        let loader = StubPlaybackLoader()
        let coordinator = MemoryPlaybackCoordinator(loader: loader, muteCoordinator: StubMuteCoordinator())
        let candidates = [
            makeCandidate(id: "one", kind: .photo),
            makeCandidate(id: "two", kind: .video),
            makeCandidate(id: "three", kind: .photo),
            makeCandidate(id: "four", kind: .livePhoto)
        ]

        await coordinator.activate(candidate: candidates[1], in: candidates, targetSize: CGSize(width: 320, height: 640))

        XCTAssertEqual(Set(loader.loadedIdentifiers), Set(["one", "two", "three"]))
        XCTAssertEqual(coordinator.currentCandidate?.localIdentifier, "two")
        XCTAssertEqual(coordinator.previousCandidate?.localIdentifier, "one")
        XCTAssertEqual(coordinator.nextCandidate?.localIdentifier, "three")
        XCTAssertNotNil(coordinator.presentation(for: candidates[0]))
        XCTAssertNotNil(coordinator.presentation(for: candidates[1]))
        XCTAssertNotNil(coordinator.presentation(for: candidates[2]))
        XCTAssertNil(coordinator.presentation(for: candidates[3]))
    }

    func testActivateTrimsOldCachedPresentationsWhenWindowChanges() async {
        let loader = StubPlaybackLoader()
        let coordinator = MemoryPlaybackCoordinator(loader: loader, muteCoordinator: StubMuteCoordinator())
        let candidates = [
            makeCandidate(id: "one", kind: .photo),
            makeCandidate(id: "two", kind: .photo),
            makeCandidate(id: "three", kind: .photo),
            makeCandidate(id: "four", kind: .photo)
        ]

        await coordinator.activate(candidate: candidates[1], in: candidates, targetSize: CGSize(width: 320, height: 640))
        await coordinator.activate(candidate: candidates[3], in: candidates, targetSize: CGSize(width: 320, height: 640))

        XCTAssertNil(coordinator.presentation(for: candidates[0]))
        XCTAssertNil(coordinator.presentation(for: candidates[1]))
        XCTAssertNotNil(coordinator.presentation(for: candidates[2]))
        XCTAssertNotNil(coordinator.presentation(for: candidates[3]))
    }

    private func makeCandidate(id: String, kind: MediaKind) -> MemoryCandidate {
        MemoryCandidate(
            localIdentifier: id,
            mediaKind: kind,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: nil,
            duration: kind == .video ? 14 : nil,
            pixelWidth: 1080,
            pixelHeight: 1920,
            isFavorite: false,
            isScreenshot: false,
            isScreenRecording: false,
            burstIdentifier: nil,
            status: .eligible,
            recoveryKey: MediaRecoveryKey(
                mediaKind: kind,
                creationDate: nil,
                modificationDate: nil,
                pixelWidth: 1080,
                pixelHeight: 1920,
                duration: nil,
                burstIdentifier: nil
            )
        )
    }
}

private actor StubMuteCoordinator: PlaybackCoordinating {
    var isMuted: Bool = true

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }
}

@MainActor
private final class StubPlaybackLoader: MemoryPlaybackAssetLoading {
    private(set) var loadedIdentifiers: [String] = []

    func loadPresentation(for candidate: MemoryCandidate, targetSize: CGSize) async throws -> MemoryPlaybackPresentation {
        loadedIdentifiers.append(candidate.localIdentifier)
        return .photo(Self.placeholderImage)
    }

    private static let placeholderImage: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }()
}
