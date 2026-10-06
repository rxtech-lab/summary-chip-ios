import XCTest

nonisolated final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testWelcomeAdvancesThroughFeaturesAndCanBeReopened() {
        let app = launchPreview()
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].waitForExistence(timeout: 10))
        capture(app, name: "Welcome-Safari")
        app.buttons["education-next"].tap()
        XCTAssertTrue(app.staticTexts["Just ask Siri"].waitForExistence(timeout: 5))
        capture(app, name: "Welcome-Siri")
        app.buttons["education-next"].tap()
        XCTAssertTrue(app.staticTexts["Share on your terms"].waitForExistence(timeout: 5))
        capture(app, name: "Welcome-Sharing")
        app.buttons["education-next"].tap()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 5))
        capture(app, name: "Siri-Feature")
        app.buttons["education-next"].tap()
        XCTAssertTrue(app.staticTexts["Connect your AI agents"].waitForExistence(timeout: 5))
        capture(app, name: "MCP-Feature")
        app.buttons["education-next"].tap()
        XCTAssertTrue(app.staticTexts["Meet your Trip Diary"].waitForExistence(timeout: 5))
        capture(app, name: "Trip-Diary-Feature")
        app.buttons["education-next"].tap()
        XCTAssertTrue(app.navigationBars["Onboarding Preview"].waitForExistence(timeout: 5))
        app.buttons["Welcome Tour"].tap()
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.buttons["What’s New"].tap()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 5))
    }

    @MainActor private func launchPreview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-education"]
        app.launch()
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
