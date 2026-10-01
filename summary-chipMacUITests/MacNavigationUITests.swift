import XCTest

nonisolated final class MacNavigationUITests: XCTestCase {
    @MainActor
    func testSettingsReopensWelcomeAndNewFeatures() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mac"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mac-sidebar"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["mac-settings"].click()

        let welcome = app.buttons["settings-welcome"]
        let features = app.buttons["settings-features"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        XCTAssertTrue(features.exists)

        welcome.click()
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Just ask Siri"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))

        features.click()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 5))
        app.buttons["Got it"].click()
        XCTAssertTrue(features.waitForExistence(timeout: 5))

        welcome.click()
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
        XCTAssertTrue(features.waitForExistence(timeout: 5))
        features.click()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
    }

    @MainActor
    func testSidebarAndDedicatedCreationSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mac"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mac-sidebar"].waitForExistence(timeout: 10))

        app.buttons["open-search"].click()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        app.textFields["search-input"].typeText("summary")
        app.buttons["close-search"].click()
        XCTAssertFalse(app.textFields["search-input"].exists)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertFalse(app.textFields["search-input"].exists)
        app.descendants(matching: .any)["mac-settings"].click()
        XCTAssertTrue(app.buttons["settings-welcome"].waitForExistence(timeout: 5))
        app.buttons["settings-welcome"].click()
        XCTAssertTrue(app.buttons["education-next"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["new-summary-input"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["generate-summary"].isEnabled)
        app.textFields["new-summary-input"].click()
        app.textFields["new-summary-input"].typeText("A short piece of text to summarise.")
        XCTAssertTrue(app.buttons["generate-summary"].isEnabled)
        app.buttons["Choose a PDF…"].click()
        XCTAssertTrue(app.descendants(matching: .any)["open-panel"].waitForExistence(timeout: 5))
        app.buttons["CancelButton"].click()
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.textFields["new-summary-input"].exists)
    }

    @MainActor
    func testWelcomeAdvancesOnMac() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-education"]
        app.launch()
        let next = app.buttons["education-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].exists)
        next.click()
        XCTAssertTrue(app.staticTexts["Just ask Siri"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertTrue(app.staticTexts["Share on your terms"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertFalse(next.exists)
    }
}
