import Foundation

actor TemporaryMediaSharingClient: MediaSharingClient {
    private let photoLibrary: PhotoLibraryClient
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private var issuedFiles: [URL: Date] = [:]

    init(
        photoLibrary: PhotoLibraryClient,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MemoriesShare", isDirectory: true)
    ) {
        self.photoLibrary = photoLibrary
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func prepareShareURL(for candidate: MemoryCandidate) async throws -> URL {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)

        let url = temporaryDirectory.appendingPathComponent(exportFileName(for: candidate))

        switch candidate.mediaKind {
        case .photo, .livePhoto:
            guard let data = try await photoLibrary.fetchImageData(localIdentifier: candidate.localIdentifier, targetSize: nil) else {
                throw SharingError.missingSourceData(candidate.localIdentifier)
            }
            try data.write(to: url, options: .atomic)
        case .video:
            guard let sourceURL = try await photoLibrary.fetchVideoURL(localIdentifier: candidate.localIdentifier) else {
                throw SharingError.missingSourceData(candidate.localIdentifier)
            }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.copyItem(at: sourceURL, to: url)
        }

        issuedFiles[url] = Date()
        return url
    }

    func cleanupExpiredTemporaryFiles() async {
        for (url, _) in issuedFiles {
            try? fileManager.removeItem(at: url)
            issuedFiles.removeValue(forKey: url)
        }
    }

    private func exportFileName(for candidate: MemoryCandidate) -> String {
        let ext: String
        switch candidate.mediaKind {
        case .photo, .livePhoto:
            ext = "jpg"
        case .video:
            ext = "mov"
        }
        return "\(candidate.localIdentifier).\(ext)"
    }
}

enum SharingError: LocalizedError {
    case missingSourceData(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceData(let identifier):
            "Unable to prepare a temporary share file for \(identifier)."
        }
    }
}
