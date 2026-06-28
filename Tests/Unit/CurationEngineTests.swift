import XCTest
@testable import Memories

final class CurationEngineTests: XCTestCase {
    func testSmartRandomAvoidsAlreadyViewedItems() async throws {
        let cycleStore = InMemoryCycleStore(viewed: ["two"])
        let engine = MemoryCurationEngine(cycleStore: cycleStore)
        let candidates = [
            makeCandidate(id: "one", favorite: false, width: 800, height: 800),
            makeCandidate(id: "two", favorite: true, width: 3000, height: 3000),
            makeCandidate(id: "three", favorite: true, width: 2200, height: 2200)
        ]

        let result = try await engine.curateCycle(from: candidates, filter: .default)

        XCTAssertEqual(result.signature.rawValue, MemoryCycleSignature(filter: .default).rawValue)
        XCTAssertFalse(result.orderedCandidates.contains { $0.localIdentifier == "two" })
        XCTAssertEqual(result.orderedCandidates.first?.localIdentifier, "three")
    }

    func testPureRandomPreservesOnlyUnviewedUnblockedCandidates() async throws {
        let cycleStore = InMemoryCycleStore(viewed: ["one"])
        let engine = MemoryCurationEngine(cycleStore: cycleStore)
        var blocked = makeCandidate(id: "three", favorite: false, width: 1000, height: 1000)
        blocked.status = .blocked

        let result = try await engine.curateCycle(
            from: [makeCandidate(id: "one", favorite: false, width: 1000, height: 1000), makeCandidate(id: "two", favorite: false, width: 1000, height: 1000), blocked],
            filter: MemoryFilter(
                preset: nil,
                yearFrom: nil,
                yearTo: nil,
                mediaKinds: Set(MediaKind.allCases),
                selectionMode: .pureRandom,
                includesScreenshots: false,
                includesScreenRecordings: false
            )
        )

        XCTAssertEqual(result.orderedCandidates.map(\.localIdentifier), ["two"])
    }

    private func makeCandidate(id: String, favorite: Bool, width: Int, height: Int) -> MemoryCandidate {
        MemoryCandidate(
            localIdentifier: id,
            mediaKind: .photo,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: nil,
            duration: nil,
            pixelWidth: width,
            pixelHeight: height,
            isFavorite: favorite,
            isScreenshot: false,
            isScreenRecording: false,
            burstIdentifier: nil,
            status: .eligible,
            recoveryKey: MediaRecoveryKey(
                mediaKind: .photo,
                creationDate: nil,
                modificationDate: nil,
                pixelWidth: width,
                pixelHeight: height,
                duration: nil,
                burstIdentifier: nil
            )
        )
    }
}

private actor InMemoryCycleStore: MemoryCycleStore {
    var viewed: [String]

    init(viewed: [String]) {
        self.viewed = viewed
    }

    func viewedIdentifiers(for signature: MemoryCycleSignature) async throws -> [String] {
        viewed
    }

    func recordViewed(identifier: String, signature: MemoryCycleSignature) async throws {
        viewed.append(identifier)
    }

    func resetCycle(for signature: MemoryCycleSignature) async throws {
        viewed.removeAll()
    }
}
