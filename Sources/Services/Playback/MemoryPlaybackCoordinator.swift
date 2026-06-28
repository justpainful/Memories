import AVFoundation
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
enum MemoryPlaybackPresentation {
    case photo(UIImage)
    case video(URL)
    case livePhoto(PHLivePhoto)
}

@MainActor
protocol MemoryPlaybackAssetLoading {
    func loadPresentation(for candidate: MemoryCandidate, targetSize: CGSize) async throws -> MemoryPlaybackPresentation
}

@MainActor
struct PhotoLibraryPlaybackAssetLoader: MemoryPlaybackAssetLoading {
    let photoLibrary: PhotoLibraryClient

    func loadPresentation(for candidate: MemoryCandidate, targetSize: CGSize) async throws -> MemoryPlaybackPresentation {
        switch candidate.mediaKind {
        case .photo:
            let data = try await photoLibrary.fetchImageData(localIdentifier: candidate.localIdentifier, targetSize: targetSize)
            guard let data, let image = UIImage(data: data) else {
                throw MemoryPlaybackError.missingImageData(candidate.localIdentifier)
            }
            return .photo(image)

        case .video:
            guard let url = try await photoLibrary.fetchVideoURL(localIdentifier: candidate.localIdentifier) else {
                throw MemoryPlaybackError.missingVideoURL(candidate.localIdentifier)
            }
            return .video(url)

        case .livePhoto:
            guard let livePhoto = try await photoLibrary.fetchLivePhoto(localIdentifier: candidate.localIdentifier, targetSize: targetSize) else {
                throw MemoryPlaybackError.missingLivePhoto(candidate.localIdentifier)
            }
            return .livePhoto(livePhoto)
        }
    }
}

enum MemoryPlaybackError: Error, Equatable {
    case missingImageData(String)
    case missingVideoURL(String)
    case missingLivePhoto(String)
}

actor ProcessPlaybackCoordinator: PlaybackCoordinating {
    static let shared = ProcessPlaybackCoordinator()

    private var muted = true

    var isMuted: Bool {
        muted
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
    }
}

@MainActor
@Observable
final class MemoryPlaybackCoordinator {
    private let loader: MemoryPlaybackAssetLoading
    private let muteCoordinator: PlaybackCoordinating

    private(set) var orderedCandidates: [MemoryCandidate] = []
    private(set) var currentCandidate: MemoryCandidate?
    private(set) var previousCandidate: MemoryCandidate?
    private(set) var nextCandidate: MemoryCandidate?
    private(set) var presentations: [String: MemoryPlaybackPresentation] = [:]
    private(set) var isPreparing = false
    private(set) var isMuted = true
    private(set) var lastError: Error?

    init(
        loader: MemoryPlaybackAssetLoading,
        muteCoordinator: PlaybackCoordinating = ProcessPlaybackCoordinator.shared
    ) {
        self.loader = loader
        self.muteCoordinator = muteCoordinator
    }

    func configure() async {
        isMuted = await muteCoordinator.isMuted
    }

    func setMuted(_ muted: Bool) async {
        await muteCoordinator.setMuted(muted)
        isMuted = muted
    }

    func toggleMuted() async {
        await setMuted(!isMuted)
    }

    func presentation(for candidate: MemoryCandidate) -> MemoryPlaybackPresentation? {
        presentations[candidate.localIdentifier]
    }

    static func appCoordinator(
        photoLibrary: PhotoLibraryClient,
        muteCoordinator: PlaybackCoordinating = ProcessPlaybackCoordinator.shared
    ) -> MemoryPlaybackCoordinator {
        MemoryPlaybackCoordinator(
            loader: PhotoLibraryPlaybackAssetLoader(photoLibrary: photoLibrary),
            muteCoordinator: muteCoordinator
        )
    }

    func activate(
        candidate: MemoryCandidate,
        in candidates: [MemoryCandidate],
        targetSize: CGSize
    ) async {
        orderedCandidates = candidates

        guard let index = candidates.firstIndex(where: { $0.localIdentifier == candidate.localIdentifier }) else {
            currentCandidate = nil
            previousCandidate = nil
            nextCandidate = nil
            presentations.removeAll()
            return
        }

        currentCandidate = candidates[index]
        previousCandidate = index > 0 ? candidates[index - 1] : nil
        nextCandidate = index < candidates.index(before: candidates.endIndex) ? candidates[index + 1] : nil

        let window = [previousCandidate, currentCandidate, nextCandidate].compactMap { $0 }
        let keepIdentifiers = Set(window.map(\.localIdentifier))

        isPreparing = true
        lastError = nil

        for preloadCandidate in window where presentations[preloadCandidate.localIdentifier] == nil {
            do {
                let presentation = try await loader.loadPresentation(for: preloadCandidate, targetSize: targetSize)
                presentations[preloadCandidate.localIdentifier] = presentation
            } catch {
                if preloadCandidate.localIdentifier == currentCandidate?.localIdentifier {
                    lastError = error
                }
            }
        }

        presentations = presentations.filter { keepIdentifiers.contains($0.key) }
        isPreparing = false
    }
}
