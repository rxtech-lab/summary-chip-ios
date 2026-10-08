import XCTest

/// The Mac paper editor on its preview host: the completion list (with descriptions) opens while
/// typing a command and Return picks; hovering a command shows its description. Set
/// `TEST_RUNNER_PAPER_SHOTS` to a folder to keep screenshots of each step.
nonisolated final class PaperEditorUITests: XCTestCase {
    @MainActor func testCompletesAndDescribesOnHover() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-paper-editor", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)

        // Hover `\documentclass` on the first line.
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 20)).hover()
        XCTAssertTrue(app.staticTexts["The document class: article, report, book, beamer…"].waitForExistence(timeout: 5), app.debugDescription)
        snapshot("mac-1-hover")

        // Below the last line puts the caret at the end; then start a command.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).click()
        editor.typeText("\n\\fra")
        XCTAssertTrue(app.staticTexts["\\frac"].waitForExistence(timeout: 5), app.debugDescription)
        snapshot("mac-2-completions")

        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("1")
        let text = editor.value as? String ?? ""
        XCTAssertTrue(text.hasSuffix("\\frac{1}{}"), "Got: \(text.suffix(40))")
        snapshot("mac-3-picked")
    }

    @MainActor private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PAPER_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }
}
