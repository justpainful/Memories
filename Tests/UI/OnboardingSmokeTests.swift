import XCTest

final class OnboardingSmokeTests: XCTestCase {
    func test_mock_onboarding_walkthrough() {
        let app = XCUIApplication()
        app.launchEnvironment["MEMORIES_UI_TEST_SCENARIO"] = "onboarding-mock"
        app.launch()

        XCTAssertTrue(app.otherElements["onboarding.step.reveal"].waitForExistence(timeout: 2))
        app.buttons["onboarding.continue"].tap()

        XCTAssertTrue(app.otherElements["onboarding.step.profile"].waitForExistence(timeout: 2))
        let nameField = app.textFields["onboarding.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText("Ava")
        app.buttons["onboarding.continue"].tap()

        XCTAssertTrue(app.otherElements["onboarding.step.privacy"].waitForExistence(timeout: 2))
        app.buttons["onboarding.continue"].tap()

        XCTAssertTrue(app.otherElements["onboarding.step.permission"].waitForExistence(timeout: 2))
        app.buttons["onboarding.permission.request"].tap()
        XCTAssertTrue(app.staticTexts["onboarding.permission.status"].waitForExistence(timeout: 2))
        app.buttons["onboarding.continue"].tap()

        XCTAssertTrue(app.otherElements["onboarding.step.theme"].waitForExistence(timeout: 2))
        app.buttons["onboarding.theme.reflectiveDark"].tap()
        app.buttons["onboarding.continue"].tap()

        XCTAssertTrue(app.otherElements["onboarding.step.avatar"].waitForExistence(timeout: 2))
        app.buttons["onboarding.avatar.avatar-ocean"].tap()
        app.buttons["onboarding.continue"].tap()

        XCTAssertTrue(app.otherElements["onboarding.step.finish"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Reflective Dark"].exists)
    }
}
