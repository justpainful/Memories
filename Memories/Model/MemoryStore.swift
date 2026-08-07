import Foundation
import SwiftData

/// The app's single SwiftData stack.
///
/// Stored on disk, never synced: there is no CloudKit container and no account, so the
/// database cannot leave the device even by accident.
enum MemoryStore {
    static let schema = Schema([
        AssetRecord.self,
        SimilarityCluster.self,
        EventCluster.self,
        MemoryRecord.self,
        ExposureRecord.self,
        CollectionRecord.self,
        AnalysisState.self,
        UserPreference.self,
    ])

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A store that cannot be opened is unrecoverable for a cache-shaped database,
            // and everything in it can be rebuilt from Photos. Start clean rather than die.
            if !inMemory, let url = configuration.url as URL? {
                try? FileManager.default.removeItem(at: url)
                if let retry = try? ModelContainer(for: schema, configurations: [configuration]) {
                    return retry
                }
            }
            return try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }
}

extension ModelContext {
    /// Fetch the singleton row of a model that has exactly one, creating it on first use.
    func singleton<T: PersistentModel>(_ type: T.Type, make: () -> T) -> T {
        var descriptor = FetchDescriptor<T>()
        descriptor.fetchLimit = 1
        if let existing = try? fetch(descriptor).first {
            return existing
        }
        let created = make()
        insert(created)
        return created
    }

    var analysisState: AnalysisState { singleton(AnalysisState.self) { AnalysisState() } }
    var userPreference: UserPreference { singleton(UserPreference.self) { UserPreference() } }

    /// Save only when there is something to save; SwiftData throws less that way and the
    /// indexer calls this on a tight loop.
    func saveIfNeeded() {
        guard hasChanges else { return }
        try? save()
    }
}
