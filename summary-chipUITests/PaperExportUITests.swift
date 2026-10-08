import XCTest

nonisolated final class PaperExportUITests: XCTestCase {
    @MainActor func testMenuAndRenderingAreAvailableFromExport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-paper-export", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let more = app.buttons["paper-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["paper-toolbar-add-image"].exists)
        more.tap()
        XCTAssertTrue(app.buttons["paper-add-image"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["paper-share"].exists)
        app.buttons["paper-rendering-options"].tap()
        XCTAssertTrue(app.navigationBars["Rendering Options"].waitForExistence(timeout: 3))
        screenshot("rendering-options")
        app.buttons["paper-rendering-presets"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let preset = app.buttons["Two-column Paper"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        app.buttons["paper-rendering-save"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(app.buttons["paper-export"].waitForExistence(timeout: 3))
        app.buttons["paper-export"].tap()
        XCTAssertTrue(app.buttons["paper-export-format"].waitForExistence(timeout: 5))
        screenshot("export-options")
        app.buttons["paper-export-rendering"].tap()
        XCTAssertTrue(app.navigationBars["Rendering Options"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.switches["paper-rendering-enabled"].value as? String, "1")
        XCTAssertTrue(app.buttons["paper-rendering-columns"].label.contains("Two Columns"))
        screenshot("saved-two-column-style")
    }

    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
