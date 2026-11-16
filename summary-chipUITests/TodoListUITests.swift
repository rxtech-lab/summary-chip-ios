import XCTest

nonisolated final class TodoListUITests: XCTestCase {
    @MainActor func testCompleteAndEditTodoInDedicatedSheets() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-todo"]
        app.launch()
        let complete = app.buttons["Complete Search investors and accelerators"]
        XCTAssertTrue(complete.waitForExistence(timeout: 15))
        complete.tap()
        XCTAssertTrue(app.buttons["Mark Search investors and accelerators incomplete"].waitForExistence(timeout: 5))
        app.buttons["Edit"].firstMatch.tap()
        let title = app.textFields["todo-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["Edit Description"].tap()
        XCTAssertTrue(app.buttons["Preview"].waitForExistence(timeout: 5))
        app.buttons["Preview"].tap()
        app.buttons["Done"].tap()
        app.buttons["Add Item"].tap()
        let itemTitle = app.textFields["todo-item-title"]
        XCTAssertTrue(itemTitle.waitForExistence(timeout: 5))
        itemTitle.tap(); itemTitle.typeText("Prepare meeting")
        app.buttons["Done"].tap()
        app.buttons["todo-save"].tap()
        XCTAssertTrue(app.buttons["Complete Prepare meeting"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Todo list after editing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
