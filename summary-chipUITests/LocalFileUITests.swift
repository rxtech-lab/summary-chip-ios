import XCTest

nonisolated final class LocalFileUITests: XCTestCase {
    @MainActor func testPreviewRemoveAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-local-file", "--reset-local-file-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["Local File"].waitForExistence(timeout: 10))
        app.buttons["Local File"].tap()
        XCTAssertTrue(app.buttons["open-local-file"].waitForExistence(timeout: 5))
        let sheetScreenshot = XCTAttachment(screenshot: app.screenshot())
        sheetScreenshot.name = "Local File Sheet"
        sheetScreenshot.lifetime = .keepAlways
        add(sheetScreenshot)
        app.buttons["open-local-file"].tap()
        XCTAssertTrue(app.navigationBars["Meeting"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["Meeting notes"].exists)
        app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].tap()
        XCTAssertTrue(app.buttons["remove-local-file"].waitForExistence(timeout: 5))
        app.buttons["remove-local-file"].tap()
        XCTAssertTrue(app.buttons["confirm-remove-local-file"].waitForExistence(timeout: 5))
        app.buttons["confirm-remove-local-file"].tap()
        XCTAssertTrue(app.staticTexts["File link removed."].waitForExistence(timeout: 5))
        app.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["No local file linked"].exists)
        app.buttons["link-local-file"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["No local file linked"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--preview-local-file"]
        app.launch()
        app.buttons["Local File"].tap()
        XCTAssertTrue(app.staticTexts["No local file linked"].waitForExistence(timeout: 5))
    }
}
