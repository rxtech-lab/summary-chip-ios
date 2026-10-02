import XCTest

nonisolated final class ChatStreamingUITests: XCTestCase {
    @MainActor
    func testStreamKeepsExistingBlocksInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-chat-stream", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["What did I save about AI this week?"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["What did I save about AI this week?"].click()
        let heading = app.staticTexts["Streaming layout check"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let initialY = heading.frame.minY
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            XCTAssertEqual(heading.frame.minY, initialY, accuracy: 1, "Existing Markdown must stay anchored as code and table blocks grow")
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(app.buttons["Stop"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Streaming Markdown blocks"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Stop"].click()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 3))
    }
}
