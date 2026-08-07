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
        FaceRecord.self,
        PersonRecord.self,
    ])

    /// How well the store the app is actually running on turned out.
    ///
    /// Worth publishing rather than swallowing: the two recovery rungs below both leave a
    /// working app, but they leave *different* apps. A rebuilt store re-indexes and is then
    /// itself again; an in-memory one re-indexes every single launch and loses the user's
    /// collections and loved photographs the moment they close it. That is something a person
    /// deserves to be told, and it can only be told by whoever draws the screens.
    enum Health {
        /// The store on disk opened, which is the ordinary case.
        case healthy
        /// The store on disk could not be opened and was rebuilt empty. Indexing starts again.
        case rebuilt
        /// Nothing could be opened on disk. The app runs, but nothing it learns will survive
        /// being closed.
        case inMemory
    }

    /// Only ever raised, never reset: this is a fact about the launch, not about the last call.
    /// A preview or a test that builds a second, deliberately in-memory container afterwards
    /// must not be able to report the real store as healthy on its behalf.
    private(set) static var health: Health = .healthy

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return container
        }

        // A store that cannot be opened is unrecoverable for a cache-shaped database, and
        // everything in it can be rebuilt from Photos. Start clean rather than die.
        //
        // The sidecars have to go with it. SQLite keeps a write-ahead log and a shared-memory
        // file beside the store, and removing only the store left the runtime a half of a
        // database to reopen — so the retry failed for the same reason the first attempt did,
        // and the app fell through to the memory-only rung it never needed to reach.
        if !inMemory, let url = configuration.url as URL? {
            for suffix in ["", "-wal", "-shm"] {
                let sidecar = suffix.isEmpty
                    ? url
                    : URL(fileURLWithPath: url.path + suffix)
                try? FileManager.default.removeItem(at: sidecar)
            }
            if let retry = try? ModelContainer(for: schema, configurations: [configuration]) {
                health = .rebuilt
                return retry
            }
        }

        // Last resort, and it used to be a `try!` — the only one in the app, on the launch
        // path, turning a rare SwiftData failure into an app that dies every time it is opened
        // with no way back in to repair it. There is nothing irreplaceable in this database, so
        // running without a disk behind it is a bad day and a crash on launch is a dead app.
        if let memoryOnly = try? ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        ) {
            health = .inMemory
            return memoryOnly
        }

        // Below this there is no app to degrade into: a schema the runtime rejects even with no
        // store attached is a defect in the models themselves, not a state a user can be in or
        // recover from. Said plainly, because a crash report that names this line is worth more
        // than one that names a `try!` in the middle of ordinary setup.
        fatalError("SwiftData rejected the Memories schema itself; the model definitions are invalid.")
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
