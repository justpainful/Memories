import XCTest
@testable import Memories

final class PlaybackMuteCoordinatorTests: XCTestCase {
    func testMuteStatePersistsAcrossSequentialReadsInSameProcess() async {
        let coordinator = ProcessPlaybackCoordinator()

        XCTAssertTrue(await coordinator.isMuted)

        await coordinator.setMuted(false)
        XCTAssertFalse(await coordinator.isMuted)

        await coordinator.setMuted(true)
        XCTAssertTrue(await coordinator.isMuted)
    }
}
