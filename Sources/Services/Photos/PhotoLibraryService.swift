import AVFoundation
import CoreGraphics
import Foundation
import Photos
import PhotosUI

struct PhotoAssetDescriptor: Identifiable, Hashable, Sendable {
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

    var recoveryKey: MediaRecoveryKey {
        MediaRecoveryKey(
            mediaKind: mediaKind,
            creationDate: creationDate,
            modificationDate: modificationDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            burstIdentifier: burstIdentifier
        )
    }

    var candidate: MemoryCandidate {
        MemoryCandidate(
            localIdentifier: localIdentifier,
            mediaKind: mediaKind,
            creationDate: creationDate,
            modificationDate: modificationDate,
            duration: duration,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isFavorite: isFavorite,
            isScreenshot: isScreenshot,
            isScreenRecording: isScreenRecording,
            burstIdentifier: burstIdentifier,
            status: .eligible,
            recoveryKey: recoveryKey
        )
    }
}

protocol PhotoLibraryAssetSource: Sendable {
    func authorizationStatus() async -> PhotoAuthorizationState
    func requestAuthorization() async -> PhotoAuthorizationState
    func fetchAllAssets() async throws -> [PhotoAssetDescriptor]
    func fetchAsset(localIdentifier: String) async -> PHAsset?
    func fetchImageData(localIdentifier: String, targetSize: CGSize?) async throws -> Data?
    func fetchVideoURL(localIdentifier: String) async throws -> URL?
    func fetchLivePhoto(localIdentifier: String, targetSize: CGSize) async throws -> PHLivePhoto?
    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void) async
}

final class PhotoLibraryObserver: NSObject, PhotoLibraryObserving, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let onLibraryChange: (@MainActor () -> Void)?

    override init() {
        onLibraryChange = nil
        super.init()
    }

    init(onLibraryChange: @escaping @MainActor () -> Void) {
        self.onLibraryChange = onLibraryChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    func emitChange() {
        lock.lock()
        let active = Array(continuations.values)
        lock.unlock()

        for continuation in active {
            continuation.yield()
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }

    deinit {
        if onLibraryChange != nil {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        if let onLibraryChange {
            Task { @MainActor in
                onLibraryChange()
            }
        }
        emitChange()
    }
}

struct RecoveryMatchPolicy: Sendable {
    var dateTolerance: TimeInterval = 1
    var durationTolerance: TimeInterval = 0.5
}

struct PhotoLibraryRecoveryMatcher: Sendable {
    var policy = RecoveryMatchPolicy()

    func restoreLocalIdentifier(
        for recoveryKey: MediaRecoveryKey,
        from assets: [PhotoAssetDescriptor]
    ) -> String? {
        let matches = assets.filter { descriptor in
            descriptor.mediaKind == recoveryKey.mediaKind &&
            descriptor.pixelWidth == recoveryKey.pixelWidth &&
            descriptor.pixelHeight == recoveryKey.pixelHeight &&
            matches(descriptor.creationDate, recoveryKey.creationDate, tolerance: policy.dateTolerance) &&
            matches(descriptor.modificationDate, recoveryKey.modificationDate, tolerance: policy.dateTolerance) &&
            matches(descriptor.duration, recoveryKey.duration, tolerance: policy.durationTolerance) &&
            descriptor.burstIdentifier == recoveryKey.burstIdentifier
        }

        guard matches.count == 1 else {
            return nil
        }

        return matches.first?.localIdentifier
    }

    private func matches(_ lhs: Date?, _ rhs: Date?, tolerance: TimeInterval) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) <= tolerance
        default:
            return false
        }
    }

    private func matches(_ lhs: TimeInterval?, _ rhs: TimeInterval?, tolerance: TimeInterval) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) <= tolerance
        default:
            return false
        }
    }
}

final class PhotoLibraryService: PhotoLibraryClient, PhotoLibraryObserving, @unchecked Sendable {
    private let assetSource: PhotoLibraryAssetSource
    private let stateRepository: (any MemoryStateRepository)?
    private let observer: PhotoLibraryObserver
    private let recoveryMatcher: PhotoLibraryRecoveryMatcher
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(
        assetSource: PhotoLibraryAssetSource = PhotoKitPhotoLibrarySource(),
        stateRepository: (any MemoryStateRepository)? = nil,
        observer: PhotoLibraryObserver = PhotoLibraryObserver(),
        recoveryMatcher: PhotoLibraryRecoveryMatcher = PhotoLibraryRecoveryMatcher(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.assetSource = assetSource
        self.stateRepository = stateRepository
        self.observer = observer
        self.recoveryMatcher = recoveryMatcher
        self.calendar = calendar
        self.now = now

        Task {
            await assetSource.startObservingChanges { [observer] in
                observer.emitChange()
            }
        }
    }

    func authorizationStatus() async -> PhotoAuthorizationState {
        await assetSource.authorizationStatus()
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        await assetSource.requestAuthorization()
    }

    func changes() -> AsyncStream<Void> {
        observer.changes()
    }

    func fetchCandidates(filter: MemoryFilter) async throws -> [MemoryCandidate] {
        let assets = try await assetSource.fetchAllAssets()
        let snapshot = try await stateRepository?.loadSnapshot() ?? .empty
        let savedLookup = Dictionary(uniqueKeysWithValues: snapshot.savedReferences.map { ($0.localIdentifier, $0) })
        let blockedLookup = Dictionary(uniqueKeysWithValues: snapshot.blockedReferences.map { ($0.localIdentifier, $0) })

        let filteredAssets = assets
            .filter { matchesPreset($0, preset: filter.preset) }
            .filter { matchesYearRange($0, filter: filter) }
            .filter { filter.mediaKinds.contains($0.mediaKind) }
            .filter { filter.includesScreenshots || !$0.isScreenshot }
            .filter { filter.includesScreenRecordings || !$0.isScreenRecording }

        var candidates: [MemoryCandidate] = []
        candidates.reserveCapacity(filteredAssets.count)

        for descriptor in filteredAssets {
            var candidate = descriptor.candidate
            if let blocked = blockedLookup[descriptor.localIdentifier] {
                candidate.status = blocked.status
            } else if let saved = savedLookup[descriptor.localIdentifier] {
                candidate.status = saved.status
            } else if let restored = try await restoredStatus(
                for: descriptor.recoveryKey,
                savedLookup: savedLookup,
                blockedLookup: blockedLookup
            ) {
                candidate.status = restored.status
                try await reconcilePersistedIdentifier(
                    restored,
                    with: descriptor.localIdentifier
                )
            }
            candidates.append(candidate)
        }

        return candidates.sorted {
            switch ($0.creationDate, $1.creationDate) {
            case let (lhs?, rhs?):
                return lhs > rhs
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return $0.localIdentifier < $1.localIdentifier
            }
        }
    }

    func restoreLocalIdentifier(for recoveryKey: MediaRecoveryKey) async throws -> String? {
        let assets = try await assetSource.fetchAllAssets()
        return recoveryMatcher.restoreLocalIdentifier(for: recoveryKey, from: assets)
    }

    func fetchAsset(localIdentifier: String) async -> PHAsset? {
        await assetSource.fetchAsset(localIdentifier: localIdentifier)
    }

    func fetchImageData(localIdentifier: String, targetSize: CGSize?) async throws -> Data? {
        try await assetSource.fetchImageData(localIdentifier: localIdentifier, targetSize: targetSize)
    }

    func fetchVideoURL(localIdentifier: String) async throws -> URL? {
        try await assetSource.fetchVideoURL(localIdentifier: localIdentifier)
    }

    func fetchLivePhoto(localIdentifier: String, targetSize: CGSize) async throws -> PHLivePhoto? {
        try await assetSource.fetchLivePhoto(localIdentifier: localIdentifier, targetSize: targetSize)
    }

    private func restoredStatus(
        for recoveryKey: MediaRecoveryKey,
        savedLookup: [String: PersistedMediaReference],
        blockedLookup: [String: PersistedMediaReference]
    ) async throws -> PersistedMediaReference? {
        if let blocked = blockedLookup.values.first(where: { $0.recoveryKey == recoveryKey }) {
            return blocked
        }
        if let saved = savedLookup.values.first(where: { $0.recoveryKey == recoveryKey }) {
            return saved
        }

        guard let stateRepository else {
            return nil
        }

        if let blocked = try await stateRepository.persistedReference(matching: recoveryKey, status: .blocked) {
            return blocked
        }
        if let saved = try await stateRepository.persistedReference(matching: recoveryKey, status: .saved) {
            return saved
        }

        return nil
    }

    private func reconcilePersistedIdentifier(
        _ reference: PersistedMediaReference,
        with localIdentifier: String
    ) async throws {
        guard reference.localIdentifier != localIdentifier, let stateRepository else {
            return
        }

        let updated = PersistedMediaReference(
            localIdentifier: localIdentifier,
            status: reference.status,
            recoveryKey: reference.recoveryKey,
            updatedAt: .now
        )

        switch reference.status {
        case .saved:
            try await stateRepository.markSaved(updated)
        case .blocked:
            try await stateRepository.markBlocked(updated)
        case .eligible, .missing:
            break
        }
    }

    private func matchesYearRange(_ descriptor: PhotoAssetDescriptor, filter: MemoryFilter) -> Bool {
        guard filter.yearFrom != nil || filter.yearTo != nil else {
            return true
        }

        guard let creationDate = descriptor.creationDate else {
            return false
        }

        let year = calendar.component(.year, from: creationDate)
        if let yearFrom = filter.yearFrom, year < yearFrom {
            return false
        }
        if let yearTo = filter.yearTo, year > yearTo {
            return false
        }
        return true
    }

    private func matchesPreset(_ descriptor: PhotoAssetDescriptor, preset: MemoryExplorePreset?) -> Bool {
        guard let preset else {
            return true
        }

        guard let creationDate = descriptor.creationDate else {
            return preset == .randomFromEntireLibrary
        }

        let currentDate = now()
        switch preset {
        case .thisWeekAcrossYears:
            return calendar.component(.weekOfYear, from: creationDate) == calendar.component(.weekOfYear, from: currentDate)
        case .previousWeekAcrossYears:
            guard let anchor = calendar.date(byAdding: .weekOfYear, value: -1, to: currentDate) else {
                return false
            }
            return calendar.component(.weekOfYear, from: creationDate) == calendar.component(.weekOfYear, from: anchor)
        case .nextWeekAcrossYears:
            guard let anchor = calendar.date(byAdding: .weekOfYear, value: 1, to: currentDate) else {
                return false
            }
            return calendar.component(.weekOfYear, from: creationDate) == calendar.component(.weekOfYear, from: anchor)
        case .onThisDay:
            let lhs = calendar.dateComponents([.month, .day], from: creationDate)
            let rhs = calendar.dateComponents([.month, .day], from: currentDate)
            return lhs.month == rhs.month && lhs.day == rhs.day
        case .randomFromEntireLibrary:
            return true
        }
    }
}

final class MockPhotoLibraryClient: PhotoLibraryClient, PhotoLibraryObserving, @unchecked Sendable {
    let source: InMemoryPhotoLibrarySource
    private let service: PhotoLibraryService

    convenience init(
        authorization: PhotoAuthorizationState = .authorized,
        candidates: [MemoryCandidate],
        imageData: [String: Data] = [:],
        videoURLs: [String: URL] = [:]
    ) {
        let assets = candidates.map { candidate in
            PhotoAssetDescriptor(
                localIdentifier: candidate.localIdentifier,
                mediaKind: candidate.mediaKind,
                creationDate: candidate.creationDate,
                modificationDate: candidate.modificationDate,
                duration: candidate.duration,
                pixelWidth: candidate.pixelWidth,
                pixelHeight: candidate.pixelHeight,
                isFavorite: candidate.isFavorite,
                isScreenshot: candidate.isScreenshot,
                isScreenRecording: candidate.isScreenRecording,
                burstIdentifier: candidate.burstIdentifier
            )
        }

        self.init(
            authorization: authorization,
            assets: assets,
            stateRepository: nil,
            observer: PhotoLibraryObserver()
        )

        source.imageData = imageData
        source.videoURLs = videoURLs
    }

    init(
        authorization: PhotoAuthorizationState = .authorized,
        assets: [PhotoAssetDescriptor] = [],
        stateRepository: (any MemoryStateRepository)? = nil,
        observer: PhotoLibraryObserver = PhotoLibraryObserver(),
        recoveryMatcher: PhotoLibraryRecoveryMatcher = PhotoLibraryRecoveryMatcher(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let source = InMemoryPhotoLibrarySource(
            authorization: authorization,
            assets: assets
        )
        self.source = source
        service = PhotoLibraryService(
            assetSource: source,
            stateRepository: stateRepository,
            observer: observer,
            recoveryMatcher: recoveryMatcher,
            calendar: calendar,
            now: now
        )
    }

    func authorizationStatus() async -> PhotoAuthorizationState {
        await service.authorizationStatus()
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        await service.requestAuthorization()
    }

    func fetchCandidates(filter: MemoryFilter) async throws -> [MemoryCandidate] {
        try await service.fetchCandidates(filter: filter)
    }

    func restoreLocalIdentifier(for recoveryKey: MediaRecoveryKey) async throws -> String? {
        try await service.restoreLocalIdentifier(for: recoveryKey)
    }

    func fetchAsset(localIdentifier: String) async -> PHAsset? {
        await service.fetchAsset(localIdentifier: localIdentifier)
    }

    func fetchImageData(localIdentifier: String, targetSize: CGSize?) async throws -> Data? {
        try await service.fetchImageData(localIdentifier: localIdentifier, targetSize: targetSize)
    }

    func fetchVideoURL(localIdentifier: String) async throws -> URL? {
        try await service.fetchVideoURL(localIdentifier: localIdentifier)
    }

    func fetchLivePhoto(localIdentifier: String, targetSize: CGSize) async throws -> PHLivePhoto? {
        try await service.fetchLivePhoto(localIdentifier: localIdentifier, targetSize: targetSize)
    }

    func changes() -> AsyncStream<Void> {
        service.changes()
    }

    func setAssets(_ assets: [PhotoAssetDescriptor]) {
        source.assets = assets
    }

    func simulateChange() {
        source.simulateChange()
    }
}

final class InMemoryPhotoLibrarySource: PhotoLibraryAssetSource, @unchecked Sendable {
    var authorization: PhotoAuthorizationState
    var assets: [PhotoAssetDescriptor]
    var imageData: [String: Data]
    var videoURLs: [String: URL]
    var livePhotos: [String: PHLivePhoto]
    private var onChange: (@Sendable () -> Void)?

    init(
        authorization: PhotoAuthorizationState = .authorized,
        assets: [PhotoAssetDescriptor] = [],
        imageData: [String: Data] = [:],
        videoURLs: [String: URL] = [:],
        livePhotos: [String: PHLivePhoto] = [:]
    ) {
        self.authorization = authorization
        self.assets = assets
        self.imageData = imageData
        self.videoURLs = videoURLs
        self.livePhotos = livePhotos
    }

    func authorizationStatus() async -> PhotoAuthorizationState {
        authorization
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        authorization
    }

    func fetchAllAssets() async throws -> [PhotoAssetDescriptor] {
        assets
    }

    func fetchAsset(localIdentifier: String) async -> PHAsset? {
        nil
    }

    func fetchImageData(localIdentifier: String, targetSize: CGSize?) async throws -> Data? {
        imageData[localIdentifier]
    }

    func fetchVideoURL(localIdentifier: String) async throws -> URL? {
        videoURLs[localIdentifier]
    }

    func fetchLivePhoto(localIdentifier: String, targetSize: CGSize) async throws -> PHLivePhoto? {
        livePhotos[localIdentifier]
    }

    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void) async {
        self.onChange = onChange
    }

    func simulateChange() {
        onChange?()
    }
}

final class PhotoKitPhotoLibrarySource: NSObject, PhotoLibraryAssetSource {
    private let imageManager: PHCachingImageManager
    private let photoLibrary: PHPhotoLibrary
    private let imageRequestOptions: PHImageRequestOptions
    private let videoRequestOptions: PHVideoRequestOptions
    private let livePhotoOptions: PHLivePhotoRequestOptions
    private var onChange: (@Sendable () -> Void)?

    init(
        imageManager: PHCachingImageManager = PHCachingImageManager(),
        photoLibrary: PHPhotoLibrary = .shared()
    ) {
        self.imageManager = imageManager
        self.photoLibrary = photoLibrary

        imageRequestOptions = PHImageRequestOptions()
        imageRequestOptions.isNetworkAccessAllowed = false
        imageRequestOptions.deliveryMode = .highQualityFormat
        imageRequestOptions.resizeMode = .fast

        videoRequestOptions = PHVideoRequestOptions()
        videoRequestOptions.isNetworkAccessAllowed = false
        videoRequestOptions.deliveryMode = .automatic

        livePhotoOptions = PHLivePhotoRequestOptions()
        livePhotoOptions.isNetworkAccessAllowed = false
        livePhotoOptions.deliveryMode = .highQualityFormat

        super.init()
    }

    func authorizationStatus() async -> PhotoAuthorizationState {
        Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: Self.mapAuthorization(status))
            }
        }
    }

    func fetchAllAssets() async throws -> [PhotoAssetDescriptor] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        var results: [PhotoAssetDescriptor] = []
        results.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            results.append(PhotoAssetDescriptor(asset: asset))
        }
        return results
    }

    func fetchAsset(localIdentifier: String) async -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    func fetchImageData(localIdentifier: String, targetSize: CGSize?) async throws -> Data? {
        guard let asset = await fetchAsset(localIdentifier: localIdentifier) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImageDataAndOrientation(for: asset, options: imageRequestOptions) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    func fetchVideoURL(localIdentifier: String) async throws -> URL? {
        guard let asset = await fetchAsset(localIdentifier: localIdentifier) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestAVAsset(forVideo: asset, options: videoRequestOptions) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }

    func fetchLivePhoto(localIdentifier: String, targetSize: CGSize) async throws -> PHLivePhoto? {
        guard let asset = await fetchAsset(localIdentifier: localIdentifier) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: livePhotoOptions
            ) { livePhoto, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: livePhoto)
            }
        }
    }

    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void) async {
        self.onChange = onChange
        photoLibrary.register(self)
    }

    deinit {
        photoLibrary.unregisterChangeObserver(self)
    }

    private static func mapAuthorization(_ status: PHAuthorizationStatus) -> PhotoAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        @unknown default:
            return .denied
        }
    }
}

extension PhotoKitPhotoLibrarySource: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }
}

private extension PhotoAssetDescriptor {
    init(asset: PHAsset) {
        let mediaKind: MediaKind
        switch asset.mediaType {
        case .image:
            mediaKind = asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
        case .video:
            mediaKind = .video
        default:
            mediaKind = .photo
        }

        localIdentifier = asset.localIdentifier
        self.mediaKind = mediaKind
        creationDate = asset.creationDate
        modificationDate = asset.modificationDate
        duration = asset.mediaType == .video ? asset.duration : nil
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
        isFavorite = asset.isFavorite
        isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        isScreenRecording = asset.mediaSubtypes.contains(.videoScreenRecording)
        burstIdentifier = asset.burstIdentifier
    }
}
