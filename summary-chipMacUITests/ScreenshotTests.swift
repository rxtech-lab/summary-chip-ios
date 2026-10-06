import XCTest

/// Captures the main screens on macOS for the PR screenshot comment
/// (.github/workflows/screenshots.yaml). Each screen is its own test so one that fails to load does
/// not cost the others their screenshots. Runs against the `--preview-likes` fixture; attachments
/// named `screenshot__<name>` are exported by scripts/ci/export-screenshots.sh.
nonisolated final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func test01Library() {
        let app = launch()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Northbound Japan")).firstMatch.waitForExistence(timeout: 5))
        settle()
        capture(app, "01-library")
    }

    @MainActor func test02Chat() {
        let app = launch()
        let field = chatInput(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("What did I save about Japan rail?")
        app.buttons["chat-send"].click()
        let view = app.buttons["chat-rendered-ui-call-ui"]
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Narita Express", "Narita Express")).firstMatch.waitForExistence(timeout: 5))
        settle()
        capture(app, "02-chat")

        view.click()
        XCTAssertTrue(app.descendants(matching: .any)["chat-native-ui"].firstMatch.waitForExistence(timeout: 5))
        settle()
        capture(app, "03-chat-rendered-ui")
    }

    @MainActor func test04Trip() {
        let app = launch()
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Northbound Japan")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.click()
        XCTAssertTrue(app.descendants(matching: .any)["trip-day-strip"].firstMatch.waitForExistence(timeout: 10))
        settle(2)
        capture(app, "04-trip-diary")

        // The trip-wide json-render view sits above the day cards; scroll until its last block shows.
        let title = app.staticTexts["Rail pass or pay as you go?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let verdict = app.staticTexts["Skip the pass"]
        for _ in 0..<6 where !(verdict.exists && verdict.isHittable) {
            title.scroll(byDeltaX: 0, deltaY: -200)
        }
        settle()
        capture(app, "05-trip-view")

        let picker = app.descendants(matching: .any)["trip-pane-picker"].firstMatch
        let bookings = picker.radioButtons["Bookings"].exists ? picker.radioButtons["Bookings"] : picker.buttons["Bookings"]
        XCTAssertTrue(bookings.waitForExistence(timeout: 5))
        bookings.click()
        let flight = app.descendants(matching: .any)["trip-transport-t-cx"].firstMatch
        XCTAssertTrue(flight.waitForExistence(timeout: 5))
        settle()
        capture(app, "06-trip-bookings")

        flight.click()
        let tabs = app.descendants(matching: .any)["transport-detail-tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        let live = tabs.radioButtons["Live Status"].exists ? tabs.radioButtons["Live Status"] : tabs.buttons["Live Status"]
        live.click()
        settle(2)
        capture(app, "07-trip-flight")
    }

    @MainActor func test08Likes() {
        let app = launch()
        app.descendants(matching: .any)["sidebar-likes"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["likes-feed"].waitForExistence(timeout: 10))
        settle(2)
        capture(app, "08-likes")
    }

    @MainActor func test09MCP() {
        let app = launch()
        app.descendants(matching: .any)["mac-settings"].firstMatch.click()
        let configure = app.buttons["mcp-server-settings"]
        XCTAssertTrue(configure.waitForExistence(timeout: 10))
        configure.click()
        XCTAssertTrue(app.staticTexts["Claude Code on MacBook"].waitForExistence(timeout: 10))
        settle()
        capture(app, "09-mcp")
    }

    @MainActor func test10DeepLink() {
        let app = launch()
        app.open(URL(string: "summarychip://s/NightTrn01")!)
        let open = app.buttons["deep-link-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        settle()
        capture(app, "10-deep-link-summary")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(open.waitForNonExistence(timeout: 5))
        app.open(URL(string: "summarychip://s/N0rthB0und")!)
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["trip-day-strip"].firstMatch.waitForExistence(timeout: 10))
        settle(2)
        capture(app, "11-deep-link-trip")
    }

    // MARK: Helpers

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The chat column's visibility is remembered; screenshots always show it.
        app.launchArguments = ["--preview-likes", "-ApplePersistenceIgnoreState", "YES", "-chatPanelVisible", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["Why specialty roasters are buying their own farms"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func chatInput(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["chat-input"]
        return field.exists ? field : app.textViews["chat-input"].exists ? app.textViews["chat-input"] : field
    }

    /// Lets images, maps and transitions finish before the capture.
    private func settle(_ seconds: UInt32 = 1) {
        sleep(seconds)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "screenshot__\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
