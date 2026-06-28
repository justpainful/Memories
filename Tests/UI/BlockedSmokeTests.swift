import XCTest

final class BlockedSmokeTests: XCTestCase {
    func testBlockedShowsUnavailableBannerAndCards() {
        let app = XCUIApplication()
        app.launchEnvironment["MEMORIES_UI_TEST_SCENARIO"] = "onboarding-mock"
        app.launchArguments = ["UITestsSkipOnboarding", "UITestsStartBlocked"]
        app.launch()

        XCTAssertTrue(app.otherElements["blocked.banner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["blocked.card.memory-003"].exists)
    }
}
