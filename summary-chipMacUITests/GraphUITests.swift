import XCTest

nonisolated final class GraphUITests: XCTestCase {
    /// Opening from Elements centres the node, so the second part clicks a known point of the canvas
    /// and exercises the real hit test. Accessibility frames of canvas elements aren't reliable on macOS.
    @MainActor func testNodesOpenInAPopover() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph"]
        app.launch()
        let canvas = app.descendants(matching: .any)["graph-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))

        let more = app.menuButtons["graph-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        app.menuItems["Elements"].click()
        let row = app.buttons["graph-element-node:ada"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5), "Opening from Elements shows a popover")
        XCTAssertTrue(app.descendants(matching: .any)["graph-inspector"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Graph Popover"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.typeKey(.escape, modifierFlags: [])
        let closed = NSPredicate(format: "exists == false")
        wait(for: [XCTNSPredicateExpectation(predicate: closed, object: app.popovers.firstMatch)], timeout: 5)

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5), "Clicking the node on the canvas shows a popover")
    }
}
