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

        // A shared summary link opens in a sheet. `app.open` relaunches the app, which would drop
        // the fixture's in-memory stars; the system hands the link to the running app instead.
        XCUIDevice.shared.system.open(URL(string: "summarychip://s/NightTrn01")!)
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
        // The star made in the sheet carries over.
        XCTAssertEqual(app.buttons["summary-like"].firstMatch.label, "Remove from Likes")

        // A shared trip link: star it, then open it.
        XCUIDevice.shared.system.open(URL(string: "summarychip://s/N0rthB0und")!)
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
        if !isPad {
            // The tab bar is hidden on detail pages.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.tabBars.buttons["Likes"].waitForExistence(timeout: 5))
        }
        if isPad {
            app.buttons["sidebar-likes"].firstMatch.tap()
        } else {
            app.tabBars.buttons["Likes"].tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["likes-feed"].waitForExistence(timeout: 10))
        sleep(2)
        capture(app, name: "06-likes-with-expired")
        XCTAssertTrue(app.staticTexts["Night trains are making a comeback across Europe"].waitForExistence(timeout: 5))

        // Older likes are in a separate date section below the newly starred cards. Lazy
        // sections need to scroll into view before their accessibility elements exist.
        let expiredCard = app.buttons["summary-card-s-solar"].firstMatch
        for _ in 0..<8 {
            if expiredCard.exists && expiredCard.isHittable { break }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(expiredCard.exists && expiredCard.isHittable, "Expected the expired chip in Likes")
        expiredCard.tap()
        XCTAssertTrue(app.staticTexts["Link Expired"].waitForExistence(timeout: 5))
        capture(app, name: "07-expired-like")
    }

    @MainActor func testReturningFromChipPreservesLoadedPagesAndScrollPosition() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-paged-feed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = app.descendants(matching: .any)["summary-card-scroll-24"].firstMatch
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 10))
        for _ in 0..<20 {
            if card.exists && card.isHittable { break }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(card.exists && card.isHittable, "Expected a chip from a later page: \(app.debugDescription)")
        for _ in 0..<2 {
            let previousY = card.frame.minY
            card.tap()
            XCTAssertTrue(app.buttons["summary-like"].firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 5))
            let returned = XCTAttachment(screenshot: app.screenshot())
            returned.name = "returned-feed"
            returned.lifetime = .keepAlways
            add(returned)
            XCTAssertTrue(card.exists, "Returning should retain the loaded page")
            XCTAssertEqual(card.frame.minY, previousY, accuracy: 12, "Returning should retain the viewing position")
            XCTAssertTrue(card.isHittable)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "feed-position-after-return"
        attachment.lifetime = .keepAlways
        add(attachment)
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
