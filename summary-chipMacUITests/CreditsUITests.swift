import XCTest

nonisolated final class CreditsUITests: XCTestCase {
    @MainActor func testConnectionErrorUsesNativeAlertAndCanRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-credits", "--preview-credits-error"]
        app.launch()
        app.activate()
        let alert = app.sheets["alert"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["Summary Points"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Native points connection error"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        alert.buttons["OK"].click()
        XCTAssertFalse(alert.waitForExistence(timeout: 4))
        app.buttons["Refresh Usage"].click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].click()
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Summaries & Points"].waitForExistence(timeout: 5))
    }

    @MainActor func testServerAllowanceAndTopUpOnlySheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-credits"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["120"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["7"].exists)
        XCTAssertTrue(app.staticTexts["2"].exists)
        XCTAssertFalse(app.buttons["summary-restore"].exists, "macOS tops up through Stripe, so StoreKit restore is hidden")
        let account = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        account.name = "Server allowance and points"
        account.lifetime = .keepAlways
        add(account)
        app.descendants(matching: .any)["summary-topup"].click()
        XCTAssertTrue(app.staticTexts["100 point pack"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["topup-buy-points-100"].exists)
        XCTAssertFalse(app.staticTexts["Recurring plan"].exists)
        let topup = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        topup.name = "Dedicated top-up screen"
        topup.lifetime = .keepAlways
        add(topup)
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Summaries & Points"].waitForExistence(timeout: 5))
    }
}
