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
///
/// There are three tours rather than one, and the two new ones are the point of this file now.
/// The app used to declare itself portrait-only on iPhone, and every font in it was a fixed
/// number of points — so a single portrait tour at the default text size photographed the only
/// configuration the app had ever been built for. The configurations that were never looked at
/// are exactly the ones that were broken: the largest accessibility text size, and landscape.
final class MemoriesUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Steps that photographed something other than what they went looking for.
    private var missteps: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-skipOnboarding"]
    }

    override func tearDown() {
        // A rotation outlives the test that made it, and the next tour would then photograph a
        // sideways app while claiming to be portrait.
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: The tours

    func testCaptureEverySurface() throws {
        launchAndSettle()
        tour(prefix: "")
        finish()
    }

    /// The same app at the largest text size iOS offers.
    ///
    /// This is where a fixed-height row clips its own label, a two-column layout collides with
    /// itself, and a button gets pushed off the bottom of a screen that cannot scroll. None of
    /// it is visible at the default size, which is why none of it was found.
    func testLargestTextSize() throws {
        // `UICTContentSizeCategoryAccessibilityXXXL`, and the exact spelling is the whole thing.
        // The first version of this passed `…AccessibilityExtraExtraExtraLarge`, which is the
        // Swift enum case's name and not the string UIKit reads. UIKit does not complain about a
        // category it does not recognise; it silently keeps the default. So the run went green,
        // fifteen screenshots came back named `ax-`, and every one of them was the app at the
        // ordinary text size — a whole verification lane reporting on a configuration it had
        // never actually been in.
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        launchAndSettle()
        tour(prefix: "ax-")
        finish()
    }

    /// The same app lying on its side.
    ///
    /// Unreachable until the app declared landscape at all. Everything measured against the
    /// height of a portrait phone — a hero card, a scrubber column, a panel with a fixed
    /// maximum height — fails here first.
    func testLandscape() throws {
        launchAndSettle()
        XCUIDevice.shared.orientation = .landscapeLeft
        settle()
        tour(prefix: "landscape-")
        finish()
    }

    // MARK: One tour

    private func launchAndSettle() {
        app.launch()
        allowPhotoAccess()

        // Metadata indexing is quick; the Vision passes are not. Wait for the feed to have
        // something rather than racing it.
        waitForFeed()
    }

    private func finish() {
        XCTAssertTrue(app.state == .runningForeground, "The app did not survive the tour")
        if !missteps.isEmpty {
            XCTFail("""
                The tour did not reach \(missteps.count) of its surfaces. Each line is a \
                screenshot that shows the wrong screen:
                \(missteps.joined(separator: "\n"))
                """)
        }
    }

    private func tour(prefix: String) {
        capture("\(prefix)01-home", expecting: "Memories")

        safeTap(app.buttons["Explore time"])
        capture("\(prefix)02-explore-time")
        if !safeTap(app.buttons["Close"]) { app.tap() }
        settle()

        returnToRoot()
        safeTap(app.buttons["memory.card"].firstMatch)
        capture("\(prefix)03-memory")

        // A photograph asked for by name. This used to be `buttons.element(boundBy: 2)` — the
        // third button on the screen, whatever that turned out to be — which is exactly the
        // kind of blind index that once sent the tour into Settings for nine straight steps.
        if !safeTap(app.buttons["asset.tile"].firstMatch) {
            safeTap(app.scrollViews.buttons.element(boundBy: 2))
        }
        capture("\(prefix)04-viewer")

        returnToRoot()
        safeTap(app.buttons["Timeline"].firstMatch)
        capture("\(prefix)05-timeline", expecting: "Timeline")

        returnToRoot()
        safeTap(app.buttons["Library"].firstMatch)
        capture("\(prefix)06-library", expecting: "Library")

        // Places is in this list because the fixture goes to the trouble of writing three
        // separate GPS clusters into the seed photos, and until now nothing ever photographed
        // the screen that reads them.
        for (row, name) in [("People", "07-people"), ("Best Of", "08-best-of"),
                            ("Calendar", "09-calendar"), ("Places", "10-places"),
                            ("Search", "11-search"), ("Collections", "12-collections")] {
            openRow(row)
            capture("\(prefix)\(name)", expecting: row)
            returnToRoot()
            safeTap(app.buttons["Library"].firstMatch)
        }

        openRow("Settings")
        capture("\(prefix)13-settings", expecting: "Settings")
        openRow("Local Processing")
        capture("\(prefix)14-privacy", expecting: "Privacy")

        returnToRoot()
        safeTap(app.buttons["Memories"].firstMatch)
        capture("\(prefix)15-home-again", expecting: "Memories")
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

    /// Open a row by name, scrolling to it first.
    ///
    /// The scroll is not optional. At the largest text size every list in the app is two or
    /// three screens long, so a row that sat comfortably above the fold at the default size is
    /// simply not on screen — and a tap on something that is not on screen does nothing, which
    /// the tour then reported as the app failing to open a screen. `Settings › Local Processing`
    /// was exactly that, on both device families.
    private func openRow(_ label: String) {
        let target = app.buttons[label].firstMatch
        if target.waitForExistence(timeout: 6), !target.isHittable {
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<6 where !target.isHittable {
                if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
            }
        }
        if !safeTap(target, fallback: app.staticTexts[label].firstMatch) {
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
        // The app's screenshot, not the screen's. `XCUIScreen.main.screenshot()` hands back the
        // display in its native orientation, so the whole landscape tour came out as portrait
        // images with the interface lying on its side inside them — unreadable as artifacts,
        // and unjudgeable, which for a lane whose only output is pictures is the same as not
        // running it.
        let attachment = XCTAttachment(screenshot: app.screenshot())
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
