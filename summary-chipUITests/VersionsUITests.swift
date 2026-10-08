import XCTest

/// The toolbar's version menu shows an earlier version of a summary in place, read-only, and
/// restores it as the newest version. Runs against the `--preview-likes` fixture, whose own
/// summaries have three versions. Set `SCREENSHOT_DIR` to also save PNGs.
nonisolated final class VersionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testSwitchesToAnEarlierVersionAndRestoresIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let title = "Why specialty roasters are buying their own farms"
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15))
        app.staticTexts[title].firstMatch.tap()

        openVersionMenu(app)
        // Menu toggles drop their accessibility identifier on iOS, so match the row by its label.
        let first = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "version-menu-1", "Version 1,")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        capture(app, name: "versions-01-menu")
        first.tap()

        // The earlier text shows in place, with a banner to go back or restore it.
        let banner = app.descendants(matching: .any)["version-banner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["First draft: \(title)"].waitForExistence(timeout: 5))
        sleep(1)
        capture(app, name: "versions-02-previewing")

        app.buttons["version-banner-restore"].tap()
        // The banner's own button is also labelled "Restore"; pick the dialog's.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Restore", "version-banner-restore")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture(app, name: "versions-03-confirm")
        confirm.tap()

        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["First draft: \(title)"].waitForExistence(timeout: 5))

        // The restore is the newest version in the history.
        openVersionMenu(app)
        let history = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "version-history", "All Versions")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.buttons["version-row-4"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Restored version 1"].firstMatch.exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Restored version 1")).firstMatch.exists)
        sleep(1)
        capture(app, name: "versions-04-history")
    }

    /// Versions is a submenu of "More" (the system overflow on iOS 27), where menu items drop
    /// their accessibility identifier, so it's also matched by its label.
    @MainActor private func openVersionMenu(_ app: XCUIApplication) {
        let more = app.navigationBars.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "summary-more", ["More", "Show More"])).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let versions = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", "version-menu", "Versions", "Version ")).firstMatch
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        versions.tap()
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
