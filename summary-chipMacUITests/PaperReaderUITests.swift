import XCTest

/// Reviews in the Mac paper reader (`PaperReaderPreviewHost`, `reviews` fixture): selecting a
/// passage and choosing **Add Review** in its context menu adds a review, and clicking a marked
/// passage opens its review.
nonisolated final class PaperReaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testContextMenuAddsReview() {
        let app = launch()
        let paragraph = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "reflows and grows")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10), app.debugDescription)
        // Double-clicking a word selects it; the context menu starts with Add Review.
        let word = paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 30, dy: 0))
        word.doubleClick()
        word.rightClick()
        let addReview = app.menuItems["paper-reader-add-review"]
        XCTAssertTrue(addReview.waitForExistence(timeout: 5), app.debugDescription)
        addReview.click()

        let comment = app.descendants(matching: .any)["paper-review-comment"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["paper-review-quote"].firstMatch.exists)
        comment.click()
        comment.typeText("Shorten this.")
        app.buttons["paper-review-save"].click()
        XCTAssertTrue(comment.waitForNonExistence(timeout: 5))

        app.buttons["paper-reviews-button"].firstMatch.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Shorten this.")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor func testClickingMarkedPassageOpensReview() {
        let app = launch()
        // "Text that reflows" starts its list item and has a review waiting for the agent.
        let item = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "Text that reflows")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 12, dy: 0)).click()
        XCTAssertTrue(app.descendants(matching: .any)["paper-review-detail"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "text that reflows on a small screen")).firstMatch.exists)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-paper-reader", "--reader-fixture", "reviews", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        return app
    }
}
