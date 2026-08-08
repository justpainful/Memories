import UIKit
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

    /// The same app turned on its side.
    ///
    /// A sampler rather than the full tour, and that is a decision about what this lane can
    /// honestly test rather than a gap in it.
    ///
    /// The app rotates correctly — the screenshots show nine time chips across a row that fits
    /// four in portrait, which is a landscape layout and not a portrait one stretched. What does
    /// not rotate is XCUITest's idea of where things are: `isHittable` and every coordinate
    /// gesture are computed against the display's native orientation, so on a rotated simulator
    /// the framework decides the Back button is off screen, and the tour spent eleven steps
    /// stuck on a screen it could not leave. That is the harness failing, not the app, and
    /// eleven false failures a run is worse than not asserting.
    ///
    /// So this rotates, photographs what is reachable without navigating, and stops. The
    /// wide-layout coverage that actually matters comes from the iPad, where a window can be any
    /// size at all and the tour navigates normally.
    func testLandscape() throws {
        launchAndSettle()
        XCUIDevice.shared.orientation = .landscapeLeft
        settle()

        let window = app.frame
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").frame
        print("landscape: window \(Int(window.width))x\(Int(window.height)), "
              + "screen \(Int(screen.width))x\(Int(screen.height))")

        capture("landscape-01-home")
        app.swipeUp()
        app.swipeUp()
        settle()
        capture("landscape-01b-home-scrolled")

        // The tabs are the one piece of navigation worth trying: they are found by name rather
        // than by coordinate. If a rotated simulator will not deliver the tap, the capture shows
        // the feed again, which is not a lie about anything.
        for (tab, name) in [("Timeline", "landscape-05-timeline"),
                            ("Library", "landscape-06-library")] {
            safeTap(app.buttons[tab].firstMatch)
            capture(name)
        }

        XCTAssertTrue(app.state == .runningForeground, "The app did not survive being rotated")
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

        // The same screen with the feed pushed up under the navigation bar.
        //
        // Every capture in this tour has always been taken at the top of its scroll view, where
        // a bar has nothing behind it and looks like a plain strip of background. The one thing
        // a Liquid Glass bar is *for* — refracting the photograph travelling underneath it —
        // has therefore never appeared in a single artifact, which is how the feed and the
        // Timeline came to be shipping with the glass edge effect switched off without anybody
        // seeing it.
        app.swipeUp()
        app.swipeUp()
        settle()
        capture("\(prefix)01b-home-scrolled")
        app.swipeDown()
        app.swipeDown()
        settle()

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

        // The video player, which is the one surface in this app that has never been
        // photographed.
        //
        // `04-viewer` opens whatever the memory happened to start with, and in this fixture that
        // is always a still — so every change made to playback, the transport, the scrubber and
        // the stall indicator has been shipped on the strength of reading the code. The seed
        // library carries five clips precisely so that this is possible; nothing had gone and
        // opened one. Videos is a filter in the Library, so a clip is two taps away.
        openRow("Videos")
        capture("\(prefix)16-videos", expecting: "Videos")
        if safeTap(app.buttons["asset.tile"].firstMatch) {
            // Long enough for the player item to load and the transport to read a duration off
            // it. A capture taken before that photographs a poster frame and a dead scrubber,
            // which is the state this work existed to get rid of.
            sleep(4)
            capture("\(prefix)17-video-player")
        }
        returnToRoot()
        safeTap(app.buttons["Library"].firstMatch)

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
        scrollIntoView(target, fallback: app.staticTexts[label].firstMatch)
        if !safeTap(target, fallback: app.staticTexts[label].firstMatch) {
            safeTap(app.cells.containing(.staticText, identifier: label).firstMatch)
        }
        settle()
    }

    /// Bring an element within reach, wherever it is in the list.
    ///
    /// At the largest accessibility text size the Library is three screens tall, so every row
    /// from People downwards is simply not on screen — and a tap on something that is not on
    /// screen does nothing, which the tour reported as the app failing to open seven surfaces
    /// in a row. Nothing was wrong with the app; the tour had never had to scroll before,
    /// because until this lane actually applied a large text size there was nothing to scroll to.
    ///
    /// It swipes the whole window rather than a scroll view found by index. These screens hold
    /// more than one scroll view — a row of chips, a filmstrip, a map — and `scrollViews.first`
    /// is whichever one the accessibility tree happens to list first, which on more than one
    /// screen is a horizontal one that does not move vertically at all.
    ///
    /// It also gives up going down and tries going back up, because a list short enough to have
    /// been overshot is a list the target is now above.
    private func scrollIntoView(_ element: XCUIElement, fallback: XCUIElement? = nil) {
        func reachable() -> Bool {
            if element.exists, element.isHittable { return true }
            if let fallback, fallback.exists, fallback.isHittable { return true }
            return false
        }

        guard !reachable() else { return }
        for _ in 0..<8 {
            app.swipeUp()
            if reachable() { return }
        }
        for _ in 0..<10 {
            app.swipeDown()
            if reachable() { return }
        }
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
        // The whole screen, not just the app's own window.
        //
        // On iPadOS 26 this app runs in a resizable window on the desktop, so `app.screenshot()`
        // returns the window alone — and on a rotated device it returns it clipped by the frame
        // it was captured in, which is what made the last set of artifacts look cut off. The
        // screen is the honest picture: the window, at the size the system gave it, in the place
        // the system put it.
        let attachment = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let screen, !app.navigationBars[screen].waitForExistence(timeout: 5) {
            missteps.append("  \(name).png — expected the \(screen) screen, but it shows \(whereAmI())")
        }
        dismissAnySheet()
    }

    /// Turn a screenshot the right way up.
    ///
    /// `XCUIScreen.main.screenshot()` hands back the display in its *native* orientation, which
    /// on a phone is portrait however the device is being held. So every landscape capture came
    /// back as a tall image with the interface lying on its side inside it — which is not a
    /// crop and not a bug in the app, but is unreadable, and unreadable artifacts are the same
    /// as no artifacts in a lane whose only output is pictures.
    private func upright(_ image: UIImage) -> UIImage {
        let orientation = XCUIDevice.shared.orientation
        guard orientation == .landscapeLeft || orientation == .landscapeRight else { return image }

        let turned = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: turned, format: format).image { context in
            context.cgContext.translateBy(x: turned.width / 2, y: turned.height / 2)
            context.cgContext.rotate(by: orientation == .landscapeLeft ? -.pi / 2 : .pi / 2)
            image.draw(at: CGPoint(x: -image.size.width / 2, y: -image.size.height / 2))
        }
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
