import XCTest

nonisolated final class ChatStreamingUITests: XCTestCase {
    @MainActor
    func testStreamKeepsExistingBlocksInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-chat-stream"]
        app.launch()
        app.buttons["What did I save about AI this week?"].tap()
        let heading = app.staticTexts["Streaming layout check"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let initialY = heading.frame.minY
        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline {
            XCTAssertEqual(heading.frame.minY, initialY, accuracy: 1, "Existing Markdown must stay anchored as code blocks grow")
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(app.buttons["Stop"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Streaming Markdown blocks"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // The answer now grows past the viewport. Following should hide the
        // heading, and scrolling back must release the stream's bottom anchor.
        let followsAnswer = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [followsAnswer], timeout: 10), .completed)
        // Move well beyond the list's near-bottom tolerance before scrolling
        // away, rather than testing an answer that only overflows by a few pixels.
        Thread.sleep(forTimeInterval: 4)
        for _ in 0..<4 where !heading.isHittable {
            app.collectionViews.firstMatch.swipeDown()
        }
        // UIKit's bounce/momentum can continue after the synthesized gesture.
        // Compare streamed updates only once that movement has settled.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(heading.isHittable)
        let readingY = heading.frame.minY
        let readingDeadline = Date().addingTimeInterval(3)
        while Date() < readingDeadline {
            XCTAssertEqual(heading.frame.minY, readingY, accuracy: 1, "New deltas must not pull a reader back to the bottom")
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(app.buttons["Stop"].exists)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 3))
    }
}
