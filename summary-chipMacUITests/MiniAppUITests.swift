import XCTest

nonisolated final class MiniAppUITests: XCTestCase {
    @MainActor func testKeyboardEntryAndNativeSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mini-app"]
        app.launch()
        XCTAssertTrue(app.buttons["Add Entry"].waitForExistence(timeout: 15))
        app.buttons["Add Entry"].click()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Mac entry")
        app.buttons["Save Entry"].click()
        XCTAssertTrue(app.staticTexts["Mac entry"].waitForExistence(timeout: 5))
        app.buttons["Options"].click()
        app.menuItems["Refresh"].click()
        XCTAssertTrue(app.staticTexts["Refreshed"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
}
