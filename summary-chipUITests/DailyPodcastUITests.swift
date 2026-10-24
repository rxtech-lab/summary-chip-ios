import XCTest

nonisolated final class DailyPodcastUITests: XCTestCase {
    @MainActor func testGeneratesPlaysRegeneratesAndReopensSavedPodcast() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let dayPlay = app.buttons["daily-podcast-play"].firstMatch
        XCTAssertTrue(dayPlay.waitForExistence(timeout: 15))
        dayPlay.tap()
        let generate = app.buttons["podcast-generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()
        XCTAssertTrue(app.buttons["podcast-generation-submit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Language"].exists || app.buttons["Language"].exists)
        attach(app, "daily-podcast-language")
        app.buttons["podcast-generation-submit"].tap()
        XCTAssertTrue(app.staticTexts["podcast-caption"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["podcast-toggle"].exists)
        attach(app, "daily-podcast-player")
        app.buttons["podcast-more"].tap()
        app.buttons["Regenerate Podcast"].tap()
        XCTAssertTrue(app.buttons["podcast-generation-submit"].waitForExistence(timeout: 5))
        app.buttons["podcast-generation-submit"].tap()
        let confirm = app.buttons.matching(identifier: "Regenerate Podcast").allElementsBoundByIndex.last!
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["podcast-caption"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(dayPlay.waitForExistence(timeout: 5))
        dayPlay.tap()
        XCTAssertTrue(app.staticTexts["podcast-caption"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["podcast-generate"].exists)
        app.buttons["podcast-more"].tap()
        app.buttons["Download Podcast"].tap()
        XCTAssertTrue(app.buttons["podcast-download-confirm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Format"].exists || app.buttons["podcast-download-format"].exists)
        attach(app, "daily-podcast-download")

    }

    @MainActor func testOpeningChipKeepsPlayingInMiniPlayer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-podcast-navigation", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let dayPlay = app.buttons["daily-podcast-play"].firstMatch
        XCTAssertTrue(dayPlay.waitForExistence(timeout: 15))
        dayPlay.tap()
        XCTAssertTrue(app.buttons["podcast-generate"].waitForExistence(timeout: 5))
        app.buttons["podcast-generate"].tap()
        app.buttons["podcast-generation-submit"].tap()
        XCTAssertTrue(app.buttons["podcast-open-chip"].waitForExistence(timeout: 10))
        let initial = progress(app)
        app.buttons["podcast-open-chip"].tap()
        let miniToggle = app.buttons["podcast-mini-toggle"]
        attach(app, "daily-podcast-opening-chip")
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Why specialty roasters are buying their own farms"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(miniToggle.label, "Pause")
        attach(app, "daily-podcast-reading-with-mini-player")
        app.buttons["podcast-mini-expand"].tap()
        XCTAssertTrue(app.buttons["podcast-open-chip"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["podcast-toggle"].label, "Pause")
        XCTAssertGreaterThan(progress(app), initial)
        app.buttons["Done"].tap()
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 5))
        app.buttons["podcast-mini-close"].tap()
        XCTAssertTrue(miniToggle.waitForNonExistence(timeout: 5))
    }

    @MainActor private func progress(_ app: XCUIApplication) -> Double {
        let value = app.sliders["podcast-seek"].value as? String ?? "0"
        return Double(value.replacingOccurrences(of: "%", with: "")) ?? 0
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
