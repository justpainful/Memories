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
/// **A missed tap does not stop the tour, but it does fail the run.** Abandoning at the first
/// missed control would throw away every screenshot after it, and those screenshots are the
/// entire point. So each step records where it actually landed and carries on; the assertions
/// are collected and reported together at the end. The previous arrangement — never fail on a
/// missed tap — meant a run where the tour got stuck in the photo viewer and photographed it
/// eight times still reported success, which is the one outcome worse than a red build.
final class MemoriesUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Steps that photographed something other than what they went looking for.
    private var missteps: [String] = []

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
        capture("01-home", expecting: "Memories")

        safeTap(app.buttons["Explore time"])
        capture("02-explore-time")
        if !safeTap(app.buttons["Close"]) { app.tap() }
        settle()

        returnToRoot()
        safeTap(app.buttons["memory.card"].firstMatch)
        capture("03-memory")

        safeTap(app.scrollViews.buttons.element(boundBy: 2))
        capture("04-viewer")

        returnToRoot()
        safeTap(app.buttons["Timeline"].firstMatch)
        capture("05-timeline", expecting: "Timeline")

        returnToRoot()
        safeTap(app.buttons["Library"].firstMatch)
        capture("06-library", expecting: "Library")

        // Places is in this list because the fixture goes to the trouble of writing three
        // separate GPS clusters into the seed photos, and until now nothing ever photographed
        // the screen that reads them.
        for (row, name) in [("People", "07-people"), ("Best Of", "08-best-of"),
                            ("Calendar", "09-calendar"), ("Places", "10-places"),
                            ("Search", "11-search"), ("Collections", "12-collections")] {
            openRow(row)
            capture(name, expecting: row)
            returnToRoot()
            safeTap(app.buttons["Library"].firstMatch)
        }

        openRow("Settings")
        capture("13-settings", expecting: "Settings")
        openRow("Local Processing")
        capture("14-privacy", expecting: "Privacy")

        returnToRoot()
        safeTap(app.buttons["Memories"].firstMatch)
        capture("15-home-again", expecting: "Memories")

        XCTAssertTrue(app.state == .runningForeground, "The app did not survive the tour")
        if !missteps.isEmpty {
            XCTFail("""
                The tour did not reach \(missteps.count) of its surfaces. Each line is a \
                screenshot that shows the wrong screen:
                \(missteps.joined(separator: "\n"))
                """)
        }
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

    private func openRow(_ label: String) {
        if !safeTap(app.buttons[label].firstMatch, fallback: app.staticTexts[label].firstMatch) {
            safeTap(app.cells.containing(.staticText, identifier: label).firstMatch)
        }
        settle()
    }

    // MARK: Getting back

    /// The tab bar is drawn by the app's own root and stays visible over pushed screens, so it
    /// is the one signal that says whether something modal is covering everything. The photo
    /// viewer and every sheet hide it; a pushed navigation screen does not.
    private var tabBarIsReachable: Bool {
        app.buttons["Memories"].firstMatch.isHittable
    }

    /// Get back to a tab's own root before doing anything else.
    ///
    /// This is the step the tour cannot afford to get wrong. When it failed, the app stayed
    /// inside the photo viewer, the tab buttons underneath were unreachable, and every later
    /// capture photographed the same photograph — which reads in the artifacts as though the
    /// whole app were broken.
    ///
    /// It runs in two parts because there are two different things to escape, and the order
    /// matters: anything modal first (it hides the tab bar and swallows every tap), then any
    /// pushed screens underneath it.
    private func returnToRoot() {
        for _ in 0..<4 {
            if tabBarIsReachable { break }

            // A sheet has a Done button; take it if it is there.
            dismissAnySheet()
            if tabBarIsReachable { break }

            // Otherwise this is the full-screen photo viewer. Its controls fade after a couple
            // of seconds, so wake them with a tap before reaching for the Back button, and fall
            // back to the downward throw — the gesture the viewer exists to support — if the
            // button still is not there.
            app.tap()
            settle()
            if safeTap(app.buttons["Back"]) { continue }
            app.swipeDown()
            settle()
        }

        for _ in 0..<5 {
            guard popOnce() else { break }
        }
        dismissAnySheet()
    }

    /// Pop one pushed screen, and say whether there was one.
    ///
    /// It must be a *back* button, asked for by name. Reaching for the navigation bar's first
    /// button instead — which is the recipe this tour used to follow — works only on a screen
    /// that has one. On a tab root there is none, so the first button is whatever the toolbar
    /// puts there, and on this app's home screen that is the Settings gear. The tour tapped it,
    /// walked into Settings, and photographed Settings for the remaining nine steps while
    /// reporting nothing wrong.
    private func popOnce() -> Bool {
        // Hittable, because all three tab stacks stay mounted behind one another: an
        // unselected tab's back button still exists and tapping it would quietly rearrange a
        // screen nobody is looking at.
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        if back.exists, back.isHittable {
            back.tap()
            settle()
            return true
        }
        guard app.navigationBars.buttons["BackButton"].firstMatch.exists else { return false }

        // The button is there but not reachable — a glass toolbar mid-animation, usually.
        // The interactive pop gesture does not care.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        settle()
        return true
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

    /// Photograph the screen, then check it is the screen the step went looking for.
    ///
    /// The screenshot is taken first on purpose: a capture that landed on the wrong screen is
    /// the most useful picture in the artifact, so it is kept and named either way.
    private func capture(_ name: String, expecting screen: String? = nil) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let screen, !app.navigationBars[screen].waitForExistence(timeout: 5) {
            missteps.append("  \(name).png — expected the \(screen) screen, but it shows \(whereAmI())")
        }
        dismissAnySheet()
    }

    /// A short description of the screen actually on display, for the failure message. Without
    /// this a red run says only that a screenshot was wrong, and finding out which screen it
    /// settled on means opening thirteen PNGs by hand.
    private func whereAmI() -> String {
        let titles = app.navigationBars.allElementsBoundByIndex
            .map(\.identifier)
            .filter { !$0.isEmpty }
        if titles.isEmpty {
            return tabBarIsReachable ? "an untitled screen" : "a full-screen cover or sheet"
        }
        return titles.joined(separator: " › ")
    }
}
