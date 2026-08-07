import XCTest

/// Walks the whole app and photographs every screen.
///
/// This exists because the failures that matter in this project are visual — a screen
/// letterboxed into a square, a control clipped, a surface that renders empty — and a
/// compile-only CI cannot see any of them. It also serves as the crash smoke test: every
/// tab, sheet and menu here is one that would otherwise ship untried.
///
/// It additionally solves a practical problem: `simctl privacy grant photos` does not
/// actually grant photo-library access on current runtimes, so the app sits behind the
/// system permission alert. Only UI automation can answer that dialog.
///
/// The tour never fails on a missed tap. A control that is momentarily not hittable is a
/// timing artifact of driving a live animation, not a defect, and abandoning the run over
/// one would throw away every screenshot after it. Only a crash fails this test.
final class MemoriesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-skipOnboarding"]
    }

    // MARK: The tour

    func testCaptureEverySurface() throws {
        app.launch()
        allowPhotoAccess()

        // Metadata indexing is quick; the Vision passes are not. Wait for the feed to have
        // something rather than racing it.
        waitForFeed()
        capture("01-home")

        safeTap(app.buttons["Explore time"])
        capture("02-explore-time")
        if !safeTap(app.buttons["Close"]) { app.tap() }
        settle()

        safeTap(app.buttons["memory.card"].firstMatch)
        capture("03-memory")

        safeTap(app.scrollViews.buttons.element(boundBy: 2))
        capture("04-viewer")
        leaveViewer()
        goBack()
        dismissAnySheet()

        dismissAnySheet()
        safeTap(app.buttons["Timeline"].firstMatch)
        capture("05-timeline")

        safeTap(app.buttons["Library"].firstMatch)
        capture("06-library")

        openRow("Calendar")
        capture("07-calendar")
        goBack()

        openRow("Search")
        capture("08-search")
        goBack()

        openRow("Settings")
        capture("09-settings")
        openRow("Local Processing")
        capture("10-privacy")
        goBack()
        goBack()

        safeTap(app.buttons["Memories"].firstMatch)
        capture("11-home-again")

        XCTAssertTrue(app.state == .runningForeground, "The app did not survive the tour")
    }

    // MARK: Steps

    private func allowPhotoAccess() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 8) {
                button.tap()
                return
            }
        }
    }

    /// Wait until the feed stops showing its preparing state, but never fail over it — an
    /// empty feed is itself worth photographing.
    private func waitForFeed() {
        let preparing = app.staticTexts["Getting your memories ready"]
        let deadline = Date().addingTimeInterval(180)
        while preparing.exists && Date() < deadline {
            sleep(5)
        }
        settle()
    }

    private func leaveViewer() {
        let back = app.buttons["Back"]
        if !back.exists {
            app.tap()   // controls auto-hide; a tap brings them back
        }
        if !safeTap(back) {
            app.swipeDown()
        }
        settle()
    }

    private func openRow(_ label: String) {
        if !safeTap(app.buttons[label].firstMatch, fallback: app.staticTexts[label].firstMatch) {
            safeTap(app.cells.containing(.staticText, identifier: label).firstMatch)
        }
        settle()
    }

    private func goBack() {
        safeTap(app.navigationBars.buttons.element(boundBy: 0))
        settle()
    }

    /// A sheet left open swallows every later tap, and the rest of the tour then
    /// photographs the same screen eleven times.
    private func dismissAnySheet() {
        for _ in 0..<3 {
            let done = app.buttons["Done"]
            guard done.exists, done.isHittable else { return }
            done.tap()
            settle()
        }
    }

    // MARK: Helpers

    @discardableResult
    private func safeTap(_ element: XCUIElement, fallback: XCUIElement? = nil) -> Bool {
        if element.waitForExistence(timeout: 6), element.isHittable {
            element.tap()
            settle()
            return true
        }
        if let fallback, fallback.exists, fallback.isHittable {
            fallback.tap()
            settle()
            return true
        }
        return false
    }

    private func settle() {
        sleep(2)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
