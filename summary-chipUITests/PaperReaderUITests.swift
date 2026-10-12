import XCTest

/// The native paper reader on fixed LaTeX (`PaperReaderPreviewHost`): each fixture's screenshot
/// is compared with a reference image to catch style changes (see `SnapshotMatching`), and the
/// text size buttons, citation notes, figure viewer, drawings and the review flow (select text →
/// Add Review → comment; read an agent's change as a diff → Mark as Finished) are exercised.
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

    @MainActor func testDrawingsAreDrawnNatively() {
        let app = launch("figures")
        let drawing = app.buttons["paper-reader-drawing"].firstMatch
        XCTAssertTrue(drawing.waitForExistence(timeout: 10))
        XCTAssertFalse(text(app, containing: "This diagram is drawn by LaTeX.").exists)
        drawing.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
    }

    @MainActor func testSelectingTextOffersAddReview() {
        let app = launch("reviews")
        let paragraph = app.textViews["paper-reader-paragraph"].firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        // Double-tapping a word selects it and opens the selection menu, which starts with Add Review.
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).doubleTap()
        let addReview = app.menuItems["Add Review"]
        XCTAssertTrue(addReview.waitForExistence(timeout: 5))
        addReview.tap()
        XCTAssertTrue(app.navigationBars["Add Review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["paper-review-quote"].firstMatch.exists)
        let comment = app.textFields["paper-review-comment"].exists ? app.textFields["paper-review-comment"] : app.textViews["paper-review-comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        comment.typeText("Shorten this.")
        app.buttons["paper-review-save"].tap()
        XCTAssertFalse(app.navigationBars["Add Review"].waitForExistence(timeout: 2))

        app.buttons["paper-reviews-button"].tap()
        XCTAssertTrue(app.navigationBars["Reviews"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, containing: "Shorten this.").waitForExistence(timeout: 5))
    }

    @MainActor func testFinishedReviewShowsTheDiffAndMarksItFinished() {
        let app = launch("reviews", open: "diff")
        let finish = app.buttons["paper-review-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "an essay written for people").waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["paper-review-agent-note"].firstMatch.exists)
        finish.tap()
        XCTAssertTrue(app.navigationBars["Reviews"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Finished"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Ready to Review"].exists)
    }

    // MARK: Helpers

    @MainActor private func launch(_ fixture: String, open: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-paper-reader", "--reader-fixture", fixture] + (open.map { ["--reader-open", $0] } ?? [])
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
