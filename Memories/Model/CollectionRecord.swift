import Foundation
import SwiftData

/// What a collection can hold. Deliberately wider than an album: you can keep a whole
/// evening or a whole day, not just loose files.
enum CollectionItemKind: String, Codable, Sendable {
    case asset, event, day, memory
}

struct CollectionItem: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: CollectionItemKind
    /// Asset local identifier, event/memory UUID string, or an ISO day (`2026-08-07`).
    var reference: String
    var addedAt: Date = .now
}

/// A memory the user chose to keep, rather than one the engine proposed.
@Model
final class CollectionRecord {
    #Unique<CollectionRecord>([\.id])

    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var coverIdentifier: String?
    var items: [CollectionItem] = []
    /// Ordering in the Library list; lower sorts first.
    var sortIndex: Int = 0

    init(name: String) {
        self.name = name
    }

    var itemCount: Int { items.count }

    var assetReferences: [String] {
        items.filter { $0.kind == .asset }.map(\.reference)
    }

    func contains(assetIdentifier: String) -> Bool {
        items.contains { $0.kind == .asset && $0.reference == assetIdentifier }
    }
}
