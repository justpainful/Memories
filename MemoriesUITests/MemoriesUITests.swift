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
/// system permission alert. Only UI automation can answer that alert.
final class MemoriesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
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

        openExploreTime()
        capture("02-explore-time")
        dismissExploreTime()

        openFirstMemory()
        capture("03-memory")
        openFirstPhoto()
        capture("04-viewer")
        leaveViewer()
        goBack()

        tapTab("Timeline")
        capture("05-timeline")

        tapTab("Library")
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

        tapTab("Memories")
        capture("11-home-again")
    }

    // MARK: Steps

    private func allowPhotoAccess() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "OK", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 8) {
                button.tap()
                return
            }
        }
    }

    /// Wait until the feed is no longer showing its preparing state, but never fail the whole
    /// run over it — an empty feed is itself worth photographing.
    private func waitForFeed() {
        let preparing = app.staticTexts["Getting your memories ready"]
        let deadline = Date().addingTimeInterval(150)
        while preparing.exists && Date() < deadline {
            sleep(5)
        }
        sleep(3)
    }

    private func openExploreTime() {
        let explore = app.buttons["Explore time"]
        if explore.waitForExistence(timeout: 5) {
            explore.tap()
            sleep(1)
        }
    }

    private func dismissExploreTime() {
        let close = app.buttons["Close"]
        if close.exists { close.tap() } else { app.tap() }
        sleep(1)
    }

    private func openFirstMemory() {
        let first = app.scrollViews.buttons.firstMatch
        if first.waitForExistence(timeout: 5) {
            first.tap()
            sleep(3)
        }
    }

    private func openFirstPhoto() {
        let tile = app.scrollViews.buttons.element(boundBy: 2)
        if tile.exists {
            tile.tap()
            sleep(3)
        }
    }

    private func leaveViewer() {
        let back = app.buttons["Back"]
        if back.waitForExistence(timeout: 4) {
            back.tap()
        } else {
            // Controls auto-hide; a tap brings them back.
            app.tap()
            if back.waitForExistence(timeout: 3) { back.tap() }
        }
        sleep(2)
    }

    private func tapTab(_ name: String) {
        let tab = app.buttons[name].firstMatch
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
            sleep(3)
        }
    }

    private func openRow(_ label: String) {
        let row = app.buttons[label].firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap()
        } else {
            let cell = app.staticTexts[label].firstMatch
            if cell.waitForExistence(timeout: 3) { cell.tap() }
        }
        sleep(3)
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        sleep(2)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
