import XCTest

/// Shared links open in a sheet whose toolbar opens the item in the Library; shared summaries and
/// trips can be starred; starred items whose link expired show as expired in Likes.
/// Runs against the `--preview-likes` fixture. Set `TEST_RUNNER_SCREENSHOT_DIR` to also save PNGs.
nonisolated final class DeepLinkLikesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testSharedLinksCanBeLikedAndOpenedAndExpiredLikesShow() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes"]
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
        XCTAssertTrue(app.staticTexts["Why specialty roasters are buying their own farms"].waitForExistence(timeout: 15))

        // A shared summary link opens in a sheet.
        app.open(URL(string: "summarychip://s/NightTrn01")!)
        let open = app.buttons["deep-link-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Night trains are making a comeback across Europe"].waitForExistence(timeout: 5))
        capture(app, name: "01-summary-link-sheet")

        tapToolbarItem(app, id: "summary-like")
        // Catch the "Added to Likes" overlay while it's up.
        usleep(700_000)
        capture(app, name: "02-summary-liked")
        XCTAssertEqual(app.buttons["summary-like"].firstMatch.label, "Remove from Likes")

        // The sheet's toolbar opens it in the Library.
        open.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Night trains are making a comeback across Europe"].waitForExistence(timeout: 5))
        sleep(1)
        capture(app, name: "03-summary-opened-in-library")

        // A shared trip link: star it, then open it.
        app.open(URL(string: "summarychip://s/N0rthB0und")!)
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["trip-more-menu"].waitForExistence(timeout: 10))
        if isPad {
            app.buttons["trip-like"].tap()
        } else {
            app.buttons["trip-more-menu"].tap()
            XCTAssertTrue(app.buttons["trip-like"].waitForExistence(timeout: 5))
            app.buttons["trip-like"].tap()
        }
        usleep(700_000)
        capture(app, name: "04-trip-link-sheet-liked")
        open.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 5))
        sleep(1)
        capture(app, name: "05-trip-opened-in-library")

        // Likes lists both, plus a liked summary whose link has expired.
        if isPad {
            app.buttons["sidebar-likes"].firstMatch.tap()
        } else {
            app.tabBars.buttons["Likes"].tap()
        }
        let expiredBadge = app.descendants(matching: .any)["expired-badge"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["likes-feed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Night trains are making a comeback across Europe"].waitForExistence(timeout: 5))
        sleep(1)
        capture(app, name: "06-likes-with-expired")

        let expiredCard = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "balcony solar")).firstMatch
        XCTAssertTrue(expiredCard.exists || expiredBadge.exists)
        (expiredCard.exists ? expiredCard : expiredBadge).tap()
        XCTAssertTrue(app.staticTexts["Link Expired"].waitForExistence(timeout: 5))
        capture(app, name: "07-expired-like")
    }

    /// iPhone folds trailing toolbar items into an overflow menu when the bar is full.
    @MainActor private func tapToolbarItem(_ app: XCUIApplication, id: String) {
        let button = app.buttons[id].firstMatch
        if button.waitForExistence(timeout: 3), button.isHittable {
            button.tap()
            return
        }
        let overflow = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["More", "Show More"])).firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 3))
        overflow.tap()
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(name).png"))
    }
}
