import XCTest
import Foundation

nonisolated final class SoftwareUpdateUITests: XCTestCase {
    @MainActor
    func testUpdateDownloadUsesOverlayAndRejectsUnsignedArchive() async throws {
        // The test runner cannot listen for HTTP inside its sandbox. Start the
        // local fixture with scripts/tests/update-fixture-server.py first.
        do {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18765/health")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw XCTSkip("Start scripts/tests/update-fixture-server.py to run the download integration test")
            }
        } catch {
            throw XCTSkip("Start scripts/tests/update-fixture-server.py to run the download integration test")
        }
        let port = "18765"
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mac", "--test-update-feed=http://127.0.0.1:\(port)/appcast.xml"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mac-sidebar"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Chippy"].click()
        app.menuItems["Check for Updates…"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["Update Available"].waitForExistence(timeout: 10))
        sheet.buttons["Install Update"].click()
        XCTAssertTrue(sheet.descendants(matching: .any)["software-update-progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Update Failed"].waitForExistence(timeout: 15))
        sheet.buttons["Close"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testUpdateSettingsUsesDedicatedSheetAndReopens() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mac"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mac-sidebar"].waitForExistence(timeout: 10))
        for _ in 0..<2 {
            app.menuBars.menuBarItems["Chippy"].click()
            app.menuItems["Software Update Settings…"].click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            XCTAssertTrue(sheet.checkBoxes["Automatically check for updates"].exists)
            XCTAssertTrue(sheet.buttons["Check for Updates…"].exists)
            sheet.buttons["Close"].click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testManualCheckShowsFailureInSheetAndCanBeRetried() {
        let app = XCUIApplication()
        // A closed loopback port exercises Sparkle's real network failure callback.
        app.launchArguments = ["--preview-mac", "--test-update-feed=http://127.0.0.1:1/appcast.xml"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mac-sidebar"].waitForExistence(timeout: 10))
        for _ in 0..<2 {
            app.menuBars.menuBarItems["Chippy"].click()
            app.menuItems["Check for Updates…"].click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            XCTAssertTrue(sheet.staticTexts["Update Failed"].waitForExistence(timeout: 10))
            sheet.buttons["Close"].click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        }
    }
}
