import XCTest
import UIKit

nonisolated final class DailyPodcastUITests: XCTestCase {
    @MainActor func testBackgroundJobsToolbarShowsPersistentJobAndLog() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tapToolbarItem(app, id: "background-jobs-toolbar", label: "Background Jobs")
        let row = app.buttons["background-job-preview-video-job"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["background-job-render"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Script ready. Tap Render on This Device to create the video."].exists)
        attach(app, "background-job-ready-log")
        app.navigationBars["Job Details"].buttons["BackButton"].tap()
        app.buttons["Done"].tap()
        tapToolbarItem(app, id: "background-jobs-toolbar", label: "Background Jobs")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor func testPhoneLibraryActionsAndMultipleEditorsPicks() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-editor-picks", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let actions = app.buttons["library-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["library-points"].exists)
        XCTAssertFalse(app.buttons["background-jobs-toolbar"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Editor’s Pick")).firstMatch.waitForExistence(timeout: 5))
        attach(app, "multiple-editors-picks")
        actions.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Filter"].exists)
        XCTAssertTrue(app.buttons["Background Jobs"].exists)
        attach(app, "phone-library-actions")
        tapMenuItem(app, id: "library-filter", label: "Filter")
        tapMenuItem(app, id: "library-filter-more", label: "More Filters…")
        XCTAssertTrue(app.navigationBars["Filter"].waitForExistence(timeout: 5))
    }

    @MainActor func testPastingLinkAndTextIntoNewSummary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tapToolbarItem(app, id: "new-summary", label: "New")
        tapMenuItem(app, id: "new-summary-menu-summary", label: "New Summary")
        let field = app.textFields["new-summary-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for content in ["https://example.com/news", "A substantial note about the news today."] {
            UIPasteboard.general.string = content
            app.buttons["Paste"].tap()
            let matches = NSPredicate(format: "value == %@", content)
            expectation(for: matches, evaluatedWith: field)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(app.buttons["generate-summary"].isEnabled)
        }
        attach(app, "paste-link-and-text")
    }

    @MainActor func testGeneratesPlaysRegeneratesAndReopensSavedPodcast() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-podcast-playback", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        app.buttons["podcast-select-chips"].tap()
        XCTAssertTrue(app.buttons["Clear Selection"].waitForExistence(timeout: 5))
        app.buttons["Clear Selection"].tap()
        app.buttons["podcast-chip-picker-done"].tap()
        XCTAssertFalse(app.buttons["podcast-generation-submit"].isEnabled)
        app.buttons["podcast-select-chips"].tap()
        app.buttons["Select All"].tap()
        attach(app, "daily-podcast-chip-selection")
        app.buttons["podcast-chip-picker-done"].tap()
        selectAudioOnly(app)
        app.buttons["podcast-generation-submit"].tap()
        XCTAssertTrue(app.staticTexts["podcast-caption"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["podcast-toggle"].exists)
        attach(app, "daily-podcast-player")
        app.buttons["podcast-more"].tap()
        app.buttons["Regenerate Podcast"].tap()
        XCTAssertTrue(app.buttons["podcast-generation-submit"].waitForExistence(timeout: 5))
        selectAudioOnly(app)
        app.buttons["podcast-generation-submit"].tap()
        XCTAssertTrue(app.staticTexts["podcast-caption"].waitForExistence(timeout: 10))
        app.buttons["podcast-more"].tap()
        app.buttons["Manage Versions"].tap()
        XCTAssertTrue(app.buttons["Set as Default"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Remove").count, 2)
        app.buttons["Set as Default"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Default updated"].waitForExistence(timeout: 5))
        attach(app, "daily-podcast-versions")
        app.buttons["podcast-versions-done"].tap()
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
        app.launchArguments = ["--preview-likes", "--preview-podcast-playback", "--preview-podcast-navigation", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let dayPlay = app.buttons["daily-podcast-play"].firstMatch
        XCTAssertTrue(dayPlay.waitForExistence(timeout: 15))
        dayPlay.tap()
        XCTAssertTrue(app.buttons["podcast-generate"].waitForExistence(timeout: 5))
        app.buttons["podcast-generate"].tap()
        selectAudioOnly(app)
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

    @MainActor func testCreatesPodcastFromToolbarWithSearchAndSourceFilter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-podcast-playback", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tapToolbarItem(app, id: "new-summary", label: "New")
        tapMenuItem(app, id: "new-podcast", label: "New Podcast")
        XCTAssertTrue(app.buttons["podcast-select-chips"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["podcast-generation-submit"].isEnabled)
        app.buttons["podcast-select-chips"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("roasters")
        let chip = app.buttons.containing(.staticText, identifier: "Why specialty roasters are buying their own farms").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        app.buttons["podcast-source-filter"].tap()
        app.buttons["Web"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        attach(app, "new-podcast-search-chips")
        app.buttons["podcast-chip-picker-done"].tap()
        XCTAssertTrue(app.buttons["podcast-generation-submit"].isEnabled)
        selectAudioOnly(app)
        app.buttons["podcast-generation-submit"].tap()
        XCTAssertTrue(app.buttons["podcast-toggle"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["A day of discoveries"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["podcast-mini-close"].tap()
        app.staticTexts["A day of discoveries"].firstMatch.tap()
        XCTAssertTrue(app.buttons["podcast-toggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["podcast-mini-toggle"].exists)
        attach(app, "podcast-chip-detail")
    }

    /// Native toolbar groups can drop identifiers or move actions into overflow.
    @MainActor private func tapToolbarItem(_ app: XCUIApplication, id: String, label: String) {
        let button = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", id, label)
        ).firstMatch
        if button.waitForExistence(timeout: 3), button.isHittable {
            button.tap()
            return
        }
        let actions = app.buttons["library-actions"]
        if actions.exists, actions.isHittable {
            actions.tap()
            tapMenuItem(app, id: id, label: label)
            return
        }
        let overflow = app.navigationBars.buttons.matching(
            NSPredicate(format: "label IN %@", ["More", "Show More"])
        ).firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 15), "Missing toolbar overflow for \(label)")
        overflow.tap()
        tapMenuItem(app, id: id, label: label)
    }

    /// Native overflow menus can drop the original SwiftUI accessibility identifiers.
    @MainActor private func tapMenuItem(_ app: XCUIApplication, id: String, label: String) {
        let button = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", id, label)
        ).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing menu item: \(label)")
        button.tap()
    }

    @MainActor private func selectAudioOnly(_ app: XCUIApplication) {
        let picker = app.buttons["podcast-generation-media"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Audio only"].tap()
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
