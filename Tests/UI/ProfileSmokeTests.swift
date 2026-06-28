import XCTest

final class ProfileSmokeTests: XCTestCase {
    func testProfileShowsIdentityAndSettingsCards() {
        let app = XCUIApplication()
        app.launchEnvironment["MEMORIES_UI_TEST_SCENARIO"] = "onboarding-mock"
        app.launchArguments = ["UITestsSkipOnboarding", "UITestsStartProfile", "UITestsProfileName", "Jordan Lee"]
        app.launch()

        XCTAssertTrue(app.otherElements["profile.identity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["profile.card.theme"].exists)
        XCTAssertTrue(app.otherElements["profile.card.photoAccess"].exists)
        XCTAssertTrue(app.otherElements["profile.card.privacy"].exists)
    }
}
