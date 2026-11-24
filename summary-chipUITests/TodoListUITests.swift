import XCTest
import UIKit
import UniformTypeIdentifiers

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
        let save = app.buttons["todo-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let form = app.collectionViews["todo-editor-form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5), app.debugDescription)
        let newItem = form.textViews["todo-new-item"]
        for _ in 0..<5 where !(newItem.exists && newItem.isHittable) { form.swipeUp() }
        XCTAssertTrue(newItem.exists && newItem.isHittable, form.debugDescription)
        newItem.tap()
        newItem.typeText("Prepare meeting\n")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        let savedItem = app.buttons["Complete Prepare meeting"]
        for _ in 0..<5 where !savedItem.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(savedItem.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Todo list after editing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testAddItemsInline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-todo"]
        app.launch()
        let button = app.buttons["todo-new-item-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        let field = app.descendants(matching: .any).matching(identifier: "todo-new-item").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Book venue\n")
        field.typeText("Send invites\n")
        XCTAssertTrue(app.buttons["Complete Book venue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Complete Send invites"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Todo list inline add"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testMultilineItemWithPastedImageAndFile() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-todo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let newItem = app.buttons["todo-new-item-button"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        let field = app.textViews["todo-new-item"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Review")
        UIPasteboard.general.string = "\nproposal"
        paste(into: field, in: app)
        XCTAssertEqual(field.value as? String, "Review\nproposal")

        let png = try XCTUnwrap(UIImage(systemName: "checkmark")?.pngData())
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 80, height: 80))
            .pdfData { $0.beginPage() }
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "todo-attachment-"))
        for (index, item) in [[UTType.png.identifier: png], [UTType.pdf.identifier: pdf]].enumerated() {
            UIPasteboard.general.items = [item]
            paste(into: field, in: app)
            let tile = tiles.element(boundBy: index)
            XCTAssertTrue(tile.waitForExistence(timeout: 8), app.debugDescription)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Multiline todo composer with pasted attachments"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        field.typeText("\n")
        let saved = app.buttons["Complete Review\nproposal"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Done"].firstMatch.tap()
        // Returning to the foreground reloads the saved document from the preview API.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertEqual(tiles.count, 2)
    }
    @MainActor private func paste(into field: XCUIElement, in app: XCUIApplication) {
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
        // The edit menu occasionally fails to appear after a long press on a field that already holds
        // multiline text (the press lands on a glyph and only moves the caret), so retry a few times.
        for attempt in 0..<3 where !paste.exists {
            if attempt > 0 {
                // Tapping the caret toggles the edit menu; tap once to clear any half-open state first.
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tap()
                if paste.waitForExistence(timeout: 2) { break }
            }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).press(forDuration: 1.2)
            if paste.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(paste.exists, app.debugDescription)
        paste.tap()
    }
}
