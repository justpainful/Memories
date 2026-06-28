import XCTest

final class AppSmokeTests: XCTestCase {
    func testMockAppLaunchShowsAllFourTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["MEMORIES_UI_TEST_SCENARIO"] = "app-mock"
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Memories"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertTrue(app.tabBars.buttons["Blocked"].exists)
        XCTAssertTrue(app.tabBars.buttons["Profile"].exists)
    }
}
