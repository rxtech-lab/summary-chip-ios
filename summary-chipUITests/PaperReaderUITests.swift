import XCTest

/// The native paper reader on fixed LaTeX (`PaperReaderPreviewHost`): each fixture's screenshot
/// is compared with a reference image to catch style changes (see `SnapshotMatching`), and the
/// text size buttons, citation notes and figure viewer are exercised.
nonisolated final class PaperReaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testTextMatchesReference() throws {
        let app = launch("text")
        XCTAssertTrue(text(app, containing: "Reading Papers").waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "Introduction").exists)
        XCTAssertTrue(text(app, containing: "Theorem 1 (Fermat).").exists)
        try SnapshotMatching.assertMatches(settledScreenshot(app), named: "text", in: self)
    }

    @MainActor func testMathMatchesReference() throws {
        let app = launch("math")
        XCTAssertTrue(text(app, containing: "Formulas").waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"].firstMatch.exists)
        try SnapshotMatching.assertMatches(settledScreenshot(app), named: "math", in: self)
    }

    @MainActor func testFiguresMatchReference() throws {
        let app = launch("figures")
        XCTAssertTrue(app.buttons["Growth over five years."].waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "Scores by model.").exists)
        try SnapshotMatching.assertMatches(settledScreenshot(app), named: "figures", in: self)
    }

    @MainActor func testLargerTextMatchesReference() throws {
        let app = launch("text")
        let paragraph = text(app, containing: "Literate programming")
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        let before = paragraph.frame.height
        let larger = app.buttons["paper-reader-larger"]
        for _ in 0..<5 { larger.tap() }
        XCTAssertGreaterThan(paragraph.frame.height, before, "The paragraph should grow with the text size.")
        try SnapshotMatching.assertMatches(settledScreenshot(app), named: "text-larger", in: self)

        let smaller = app.buttons["paper-reader-smaller"]
        for _ in 0..<5 { smaller.tap() }
        XCTAssertEqual(paragraph.frame.height, before, accuracy: 1)
    }

    @MainActor func testCitationOpensItsReference() {
        let app = launch("text")
        let citation = app.links["[1]"].firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 10))
        citation.tap()
        XCTAssertTrue(app.navigationBars["Reference"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, containing: "Literate Programming. The Computer Journal").exists)
    }

    @MainActor func testFigureOpensToZoom() {
        let app = launch("figures")
        let figure = app.buttons["Growth over five years."]
        XCTAssertTrue(figure.waitForExistence(timeout: 10))
        figure.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(figure.waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    @MainActor private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-paper-reader", "--reader-fixture", fixture]
        app.launch()
        return app
    }

    @MainActor private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    /// The reader alone (no status bar clock), once images have loaded and the scroll indicator
    /// that flashes on appear has faded.
    @MainActor private func settledScreenshot(_ app: XCUIApplication) -> XCUIScreenshot {
        let reader = app.scrollViews["paper-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        return reader.screenshot()
    }
}
