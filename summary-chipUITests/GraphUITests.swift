import XCTest

nonisolated final class GraphUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["graph-canvas"].waitForExistence(timeout: 20))
        return app
    }

    /// A node the camera can see: the far side of the globe isn't exposed.
    @MainActor private func anyNode(_ app: XCUIApplication) -> XCUIElement {
        let node = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'graph-node-'")).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 15))
        return node
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testTappingANodeShowsItsInfoInAPopoverOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout")
        let app = launch()
        anyNode(app).tap()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["graph-inspector"].exists)
        XCTAssertFalse(app.buttons["graph-inspector-close"].exists)
        screenshot(app, "Graph Popover")
    }

    @MainActor func testTappingANodeShowsItsInfoInAHalfSheet() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone layout")
        let app = launch()
        anyNode(app).tap()
        let inspector = app.descendants(matching: .any)["graph-inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        screenshot(app, "Graph Node Info")
        // The graph stays usable behind the half sheet: rotate, then close it.
        app.buttons["graph-inspector-close"].tap()
        XCTAssertFalse(inspector.waitForExistence(timeout: 1))
    }

    @MainActor func testSwitchingTo2DKeepsNodesTappable() {
        let app = launch()
        let picker = app.segmentedControls["graph-view-mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons.element(boundBy: 1).tap()
        anyNode(app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["graph-inspector"].waitForExistence(timeout: 5))
        screenshot(app, "Graph 2D")
    }

    @MainActor func testRotatingMovesTheNodes() {
        let app = launch()
        let node = anyNode(app)
        let before = node.frame
        let canvas = app.descendants(matching: .any)["graph-canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        let moved = NSPredicate { _, _ in !node.exists || node.frame != before }
        wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5)
    }

    @MainActor func testRunningAQueryHighlightsAndIsolates() {
        let app = launch()
        app.buttons["graph-query"].tap()
        let run = app.buttons["graph-saved-query-machines"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        let count = app.staticTexts["graph-selection-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.label.hasPrefix("2 nodes"))
        screenshot(app, "Graph Highlight")
        // Show Only hides everything but the two machines from the canvas.
        app.segmentedControls["graph-selection-mode"].buttons.element(boundBy: 1).tap()
        XCTAssertFalse(app.buttons["graph-node-ada"].waitForExistence(timeout: 1))
        app.buttons["graph-selection-clear"].tap()
        XCTAssertFalse(count.waitForExistence(timeout: 1))
    }

    @MainActor func testABadQueryShowsItsError() {
        let app = launch()
        app.buttons["graph-query"].tap()
        let editor = app.textViews["graph-query-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("BROKEN")
        app.buttons["graph-query-run"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Expected MATCH'")).firstMatch.exists)
    }

    @MainActor func testSavingAQueryKeepsItForLater() {
        let app = launch()
        app.buttons["graph-query"].tap()
        let editor = app.textViews["graph-query-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("MATCH (n:Person) RETURN n")
        app.buttons["graph-query-save"].tap()
        let name = app.textFields["graph-query-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("People")
        app.buttons["graph-query-name-save"].tap()
        XCTAssertTrue(app.buttons["graph-saved-query-people"].waitForExistence(timeout: 5))
    }

    @MainActor func testAddingAndDeletingANode() {
        let app = launch()
        app.buttons["graph-add"].tap()
        app.buttons["graph-add-node"].tap()
        let label = app.textFields["graph-node-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap()
        label.typeText("Grace Hopper")
        app.buttons["graph-node-save"].tap()
        XCTAssertTrue(app.staticTexts["graph-notice"].waitForExistence(timeout: 5) || app.descendants(matching: .any)["graph-notice"].exists)

        // Find it in the list, open its info, edit, delete.
        app.buttons["graph-more"].tap()
        app.buttons["graph-elements"].tap()
        let row = app.buttons["graph-element-node:grace-hopper"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["graph-inspector"].waitForExistence(timeout: 5))
        app.buttons["graph-inspector-actions"].tap()
        app.buttons["graph-inspector-edit"].tap()
        let delete = app.buttons["graph-node-delete"]
        let form = app.collectionViews.firstMatch
        for _ in 0..<5 where !(delete.exists && delete.isHittable) { form.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons.matching(identifier: "Delete Node").allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(confirm)
        confirm?.tap()
        XCTAssertTrue(app.descendants(matching: .any)["graph-notice"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["graph-node-grace-hopper"].exists)
    }

    @MainActor func testTheAgentCanShowOnlySomeNodes() {
        let app = launch()
        app.buttons["graph-more"].tap()
        app.buttons["graph-agent"].tap()
        let input = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Show only the people")
        app.buttons["chat-send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "showing only the people")).firstMatch.waitForExistence(timeout: 10))
        // The half sheet leaves the graph visible: the selection is already on it.
        XCTAssertTrue(app.staticTexts["graph-selection-count"].waitForExistence(timeout: 5))
        screenshot(app, "Graph Agent Selection")
    }
}
