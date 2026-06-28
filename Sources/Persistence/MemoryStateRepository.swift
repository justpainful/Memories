import Foundation
import SwiftData

@Model
final class MemoryStateRecord {
    @Attribute(.unique) var recordID: String
    var statusRawValue: String
    var localIdentifier: String
    var mediaKindRawValue: String
    var creationDate: Date?
    var modificationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: TimeInterval?
    var burstIdentifier: String?
    var updatedAt: Date

    init(reference: PersistedMediaReference) {
        recordID = Self.makeRecordID(status: reference.status, localIdentifier: reference.localIdentifier)
        statusRawValue = reference.status.rawValue
        localIdentifier = reference.localIdentifier
        mediaKindRawValue = reference.recoveryKey.mediaKind.rawValue
        creationDate = reference.recoveryKey.creationDate
        modificationDate = reference.recoveryKey.modificationDate
        pixelWidth = reference.recoveryKey.pixelWidth
        pixelHeight = reference.recoveryKey.pixelHeight
        duration = reference.recoveryKey.duration
        burstIdentifier = reference.recoveryKey.burstIdentifier
        updatedAt = reference.updatedAt
    }

    static func makeRecordID(status: MemoryStatus, localIdentifier: String) -> String {
        "\(status.rawValue)|\(localIdentifier)"
    }

    var status: MemoryStatus {
        MemoryStatus(rawValue: statusRawValue) ?? .eligible
    }

    var persistedReference: PersistedMediaReference {
        PersistedMediaReference(
            localIdentifier: localIdentifier,
            status: status,
            recoveryKey: MediaRecoveryKey(
                mediaKind: MediaKind(rawValue: mediaKindRawValue) ?? .photo,
                creationDate: creationDate,
                modificationDate: modificationDate,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                duration: duration,
                burstIdentifier: burstIdentifier
            ),
            updatedAt: updatedAt
        )
    }

    func update(from reference: PersistedMediaReference) {
        recordID = Self.makeRecordID(status: reference.status, localIdentifier: reference.localIdentifier)
        statusRawValue = reference.status.rawValue
        localIdentifier = reference.localIdentifier
        mediaKindRawValue = reference.recoveryKey.mediaKind.rawValue
        creationDate = reference.recoveryKey.creationDate
        modificationDate = reference.recoveryKey.modificationDate
        pixelWidth = reference.recoveryKey.pixelWidth
        pixelHeight = reference.recoveryKey.pixelHeight
        duration = reference.recoveryKey.duration
        burstIdentifier = reference.recoveryKey.burstIdentifier
        updatedAt = reference.updatedAt
    }
}

@Model
final class MemoryCycleRecord {
    @Attribute(.unique) var signatureRawValue: String
    var viewedIdentifiers: [String]
    var updatedAt: Date

    init(signature: MemoryCycleSignature, viewedIdentifiers: [String], updatedAt: Date = .now) {
        signatureRawValue = signature.rawValue
        self.viewedIdentifiers = viewedIdentifiers
        self.updatedAt = updatedAt
    }
}

@Model
final class MemoryProfileRecord {
    @Attribute(.unique) var id: String
    var displayName: String
    var selectedThemeRawValue: String
    var lastPresentedIdentifier: String?
    var lastCurationDate: Date?
    var launchCount: Int
    var memoriesSeenCount: Int
    var avatarLocalIdentifier: String?
    var avatarCropRectX: Double?
    var avatarCropRectY: Double?
    var avatarCropRectWidth: Double?
    var avatarCropRectHeight: Double?
    var fallbackInitials: String

    init(metadata: MemoryProfileMetadata) {
        id = Self.defaultID
        displayName = metadata.displayName
        selectedThemeRawValue = metadata.selectedTheme.rawValue
        lastPresentedIdentifier = metadata.lastPresentedIdentifier
        lastCurationDate = metadata.lastCurationDate
        launchCount = metadata.launchCount
        memoriesSeenCount = metadata.memoriesSeenCount
        avatarLocalIdentifier = metadata.avatarLocalIdentifier
        avatarCropRectX = metadata.avatarCropRect?.origin.x
        avatarCropRectY = metadata.avatarCropRect?.origin.y
        avatarCropRectWidth = metadata.avatarCropRect?.size.width
        avatarCropRectHeight = metadata.avatarCropRect?.size.height
        fallbackInitials = metadata.fallbackInitials
    }

    static let defaultID = "default-profile"

    var metadata: MemoryProfileMetadata {
        MemoryProfileMetadata(
            displayName: displayName,
            selectedTheme: ThemeKind(rawValue: selectedThemeRawValue) ?? .nightSky,
            lastPresentedIdentifier: lastPresentedIdentifier,
            lastCurationDate: lastCurationDate,
            launchCount: launchCount,
            memoriesSeenCount: memoriesSeenCount,
            avatarLocalIdentifier: avatarLocalIdentifier,
            avatarCropRect: avatarCropRect,
            fallbackInitials: fallbackInitials
        )
    }

    func update(from metadata: MemoryProfileMetadata) {
        displayName = metadata.displayName
        selectedThemeRawValue = metadata.selectedTheme.rawValue
        lastPresentedIdentifier = metadata.lastPresentedIdentifier
        lastCurationDate = metadata.lastCurationDate
        launchCount = metadata.launchCount
        memoriesSeenCount = metadata.memoriesSeenCount
        avatarLocalIdentifier = metadata.avatarLocalIdentifier
        avatarCropRectX = metadata.avatarCropRect?.origin.x
        avatarCropRectY = metadata.avatarCropRect?.origin.y
        avatarCropRectWidth = metadata.avatarCropRect?.size.width
        avatarCropRectHeight = metadata.avatarCropRect?.size.height
        fallbackInitials = metadata.fallbackInitials
    }

    private var avatarCropRect: CGRect? {
        guard
            let avatarCropRectX,
            let avatarCropRectY,
            let avatarCropRectWidth,
            let avatarCropRectHeight
        else {
            return nil
        }

        return CGRect(
            x: avatarCropRectX,
            y: avatarCropRectY,
            width: avatarCropRectWidth,
            height: avatarCropRectHeight
        )
    }
}

enum MemoryPersistenceStack {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            MemoryStateRecord.self,
            MemoryCycleRecord.self,
            MemoryProfileRecord.self
        ])

        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

actor MemoryRepository: MemoryStateRepository {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func loadSnapshot() async throws -> MemoryStateSnapshot {
        MemoryStateSnapshot(
            savedReferences: try loadReferences(status: .saved),
            blockedReferences: try loadReferences(status: .blocked),
            profile: try loadProfileMetadata()
        )
    }

    func savedReferences() async throws -> [PersistedMediaReference] {
        try loadReferences(status: .saved)
    }

    func blockedReferences() async throws -> [PersistedMediaReference] {
        try loadReferences(status: .blocked)
    }

    func markSaved(_ reference: PersistedMediaReference) async throws {
        try upsert(reference.withStatus(.saved))
    }

    func markBlocked(_ reference: PersistedMediaReference) async throws {
        try upsert(reference.withStatus(.blocked))
    }

    func removeSaved(localIdentifier: String) async throws {
        try remove(status: .saved, localIdentifier: localIdentifier)
    }

    func removeBlocked(localIdentifier: String) async throws {
        try remove(status: .blocked, localIdentifier: localIdentifier)
    }

    func loadProfileMetadata() async throws -> MemoryProfileMetadata {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<MemoryProfileRecord>())
        return records.first?.metadata ?? .default
    }

    func saveProfileMetadata(_ metadata: MemoryProfileMetadata) async throws {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<MemoryProfileRecord>())
        if let record = records.first {
            record.update(from: metadata)
        } else {
            context.insert(MemoryProfileRecord(metadata: metadata))
        }
        try context.save()
    }

    func persistedReference(
        matching recoveryKey: MediaRecoveryKey,
        status: MemoryStatus
    ) async throws -> PersistedMediaReference? {
        try loadStateRecords()
            .filter { $0.status == status }
            .first(where: { $0.persistedReference.recoveryKey == recoveryKey })?
            .persistedReference
    }

    func viewedIdentifiers(for signature: MemoryCycleSignature) async throws -> [String] {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<MemoryCycleRecord>())
        return records.first(where: { $0.signatureRawValue == signature.rawValue })?.viewedIdentifiers ?? []
    }

    func recordViewed(identifier: String, signature: MemoryCycleSignature) async throws {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<MemoryCycleRecord>())

        if let record = records.first(where: { $0.signatureRawValue == signature.rawValue }) {
            if !record.viewedIdentifiers.contains(identifier) {
                record.viewedIdentifiers.append(identifier)
            }
            record.updatedAt = .now
        } else {
            context.insert(MemoryCycleRecord(signature: signature, viewedIdentifiers: [identifier]))
        }

        try context.save()
    }

    func resetCycle(for signature: MemoryCycleSignature) async throws {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<MemoryCycleRecord>())
        if let record = records.first(where: { $0.signatureRawValue == signature.rawValue }) {
            context.delete(record)
            try context.save()
        }
    }

    private func loadReferences(status: MemoryStatus) throws -> [PersistedMediaReference] {
        try loadStateRecords()
            .filter { $0.status == status }
            .map(\.persistedReference)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func upsert(_ reference: PersistedMediaReference) throws {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<MemoryStateRecord>())

        if let record = records.first(where: { $0.recordID == MemoryStateRecord.makeRecordID(status: reference.status, localIdentifier: reference.localIdentifier) }) {
            record.update(from: reference)
        } else if let record = records.first(where: {
            $0.status == reference.status && $0.persistedReference.recoveryKey == reference.recoveryKey
        }) {
            record.update(from: reference)
        } else {
            context.insert(MemoryStateRecord(reference: reference))
        }

        try context.save()
    }

    private func remove(status: MemoryStatus, localIdentifier: String) throws {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<MemoryStateRecord>())
        if let record = records.first(where: {
            $0.status == status && $0.localIdentifier == localIdentifier
        }) {
            context.delete(record)
            try context.save()
        }
    }

    private func loadStateRecords() throws -> [MemoryStateRecord] {
        let context = makeContext()
        return try context.fetch(FetchDescriptor<MemoryStateRecord>())
    }

    private func makeContext() -> ModelContext {
        ModelContext(container)
    }
}

actor ProfileRepository {
    private let memoryRepository: any MemoryStateRepository

    init(memoryRepository: any MemoryStateRepository) {
        self.memoryRepository = memoryRepository
    }

    func load() async throws -> MemoryProfileMetadata {
        try await memoryRepository.loadProfileMetadata()
    }

    func save(_ metadata: MemoryProfileMetadata) async throws {
        try await memoryRepository.saveProfileMetadata(metadata)
    }
}

actor ThemeRepository {
    private let memoryRepository: any MemoryStateRepository

    init(memoryRepository: any MemoryStateRepository) {
        self.memoryRepository = memoryRepository
    }

    func loadTheme() async throws -> ThemeKind {
        let metadata = try await memoryRepository.loadProfileMetadata()
        return metadata.selectedTheme
    }

    func saveTheme(_ theme: ThemeKind) async throws {
        var metadata = try await memoryRepository.loadProfileMetadata()
        metadata.selectedTheme = theme
        try await memoryRepository.saveProfileMetadata(metadata)
    }
}

typealias SwiftDataMemoryStateRepository = MemoryRepository

private extension PersistedMediaReference {
    func withStatus(_ status: MemoryStatus) -> PersistedMediaReference {
        PersistedMediaReference(
            localIdentifier: localIdentifier,
            status: status,
            recoveryKey: recoveryKey,
            updatedAt: updatedAt
        )
    }
}
