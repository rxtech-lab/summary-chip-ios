import XCTest

/// The paper editor on its preview host: completion from the bar above the keyboard, and brace
/// pairing. Set `TEST_RUNNER_PAPER_SHOTS` to a folder to keep screenshots of each step.
nonisolated final class PaperEditorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testCompletesFromTheBarAndPairsBraces() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-paper-editor"]
        app.launch()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        snapshot("1-opened")

        // Below the last line puts the caret at the end; then start a command.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        editor.typeText("\n\\textb")
        let suggestion = app.buttons["\\textbf"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        snapshot("2-suggestions")

        suggestion.tap()
        snapshot("3-picked")
        editor.typeText("bold}")
        let text = editor.value as? String ?? ""
        XCTAssertTrue(text.hasSuffix("\\textbf{bold}"), "Got: \(text.suffix(40))")

        // `{` adds its `}`; typing `}` steps over it.
        editor.typeText(" \\emph{x}")
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("\\emph{x}"))
        snapshot("4-typed")
    }

    @MainActor private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PAPER_SHOTS"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }
}
