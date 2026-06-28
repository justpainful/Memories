import XCTest

final class LibrarySmokeTests: XCTestCase {
    func testLibraryShowsFiltersAndShareStatus() {
        let app = XCUIApplication()
        app.launchEnvironment["MEMORIES_UI_TEST_SCENARIO"] = "onboarding-mock"
        app.launchArguments = ["UITestsSkipOnboarding", "UITestsStartLibrary"]
        app.launch()

        XCTAssertTrue(app.otherElements["library.header"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.filter.all"].exists)
        XCTAssertTrue(app.buttons["library.filter.photos"].exists)
        XCTAssertTrue(app.buttons["library.filter.videos"].exists)
        XCTAssertTrue(app.buttons["library.filter.saved"].exists)
        XCTAssertTrue(app.otherElements["library.shareStatus"].exists)
    }
}
