import XCTest

nonisolated final class MiniAppUITests: XCTestCase {
    @MainActor func testNativeFormSheetConfirmationAndState() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mini-app"]
        app.launch()
        XCTAssertTrue(app.buttons["Add Entry"].waitForExistence(timeout: 15))
        app.buttons["Add Entry"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("My first entry")
        XCTAssertTrue(app.switches["Enabled"].exists)
        app.buttons["Save Entry"].tap()
        XCTAssertTrue(app.staticTexts["My first entry"].waitForExistence(timeout: 5))
        app.buttons["Add Entry"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "My first entry")
        app.buttons["Close"].tap()
        app.buttons["Clear Entry"].tap()
        XCTAssertTrue(app.buttons["Clear Now"].waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap() }
        XCTAssertTrue(app.staticTexts["My first entry"].exists)
        app.buttons["Clear Entry"].tap(); app.buttons["Clear Now"].tap()
        XCTAssertTrue(app.staticTexts["Cleared"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Mini App Native Controls"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
