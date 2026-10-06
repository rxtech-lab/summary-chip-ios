import XCTest

/// Captures the main screens on iPhone and iPad for the PR screenshot comment
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
        if !isPad {
            app.tabBars.buttons["Chat"].tap()
        }
        let field = chatInput(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("What did I save about Japan rail?")
        app.buttons["chat-send"].tap()
        let view = app.buttons["chat-rendered-ui-call-ui"]
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Narita Express")).firstMatch.waitForExistence(timeout: 5))
        dismissKeyboard(app)
        settle()
        capture(app, "02-chat")

        view.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-native-ui"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Getting there"].waitForExistence(timeout: 5))
        settle()
        capture(app, "03-chat-rendered-ui")
    }

    @MainActor func test04Trip() {
        let app = launch()
        openTrip(app)
        let diary = app.descendants(matching: .any)["trip-day-strip"].firstMatch
        XCTAssertTrue(diary.waitForExistence(timeout: 10))
        settle(2)
        capture(app, "04-trip-diary")

        // The trip-wide json-render view sits above the day cards; scroll until its last block shows.
        // On iPhone the diary is a sheet over the map: drag its grabber up to the large detent so
        // the view shows in full. (Swipes over the map can hit its attribution link, which opens Maps.)
        let title = app.staticTexts["Rail pass or pay as you go?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        if !isPad {
            let grabber = diary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -30))
            grabber.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
            settle()
        }
        let verdict = app.staticTexts["Skip the pass"]
        for _ in 0..<4 where !(verdict.isHittable && verdict.frame.maxY < app.frame.maxY - 40) {
            let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)))
        }
        settle()
        capture(app, "05-trip-view")
        if !isPad {
            // The large detent covers the toolbar with the pane picker; lower the sheet again.
            let grabber = diary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -30))
            grabber.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
            settle()
        }

        selectPane(app, "Bookings")
        let flight = app.descendants(matching: .any)["trip-transport-t-cx"].firstMatch
        XCTAssertTrue(flight.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["trip-transport-t-nex"].firstMatch.exists)
        settle()
        capture(app, "06-trip-bookings")

        flight.tap()
        let tabs = app.segmentedControls["transport-detail-tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons["Live Status"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Gate 23")).firstMatch.waitForExistence(timeout: 10))
        settle()
        capture(app, "07-trip-flight")
    }

    @MainActor func test08Likes() {
        let app = launch()
        if isPad {
            app.descendants(matching: .any)["sidebar-likes"].firstMatch.tap()
        } else {
            app.tabBars.buttons["Likes"].tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["likes-feed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Why specialty roasters are buying their own farms"].waitForExistence(timeout: 5))
        settle(2)
        capture(app, "08-likes")
    }

    @MainActor func test09MCP() {
        let app = launch()
        if isPad {
            app.descendants(matching: .any)["mac-settings"].firstMatch.tap()
        } else {
            app.tabBars.buttons["Settings"].tap()
        }
        let configure = app.buttons["mcp-server-settings"]
        XCTAssertTrue(configure.waitForExistence(timeout: 10))
        scroll(app, to: configure)
        configure.tap()
        XCTAssertTrue(app.staticTexts["Claude Code on MacBook"].waitForExistence(timeout: 10))
        settle()
        capture(app, "09-mcp")
    }

    @MainActor func test10DeepLink() {
        let app = launch()
        app.open(URL(string: "summarychip://s/NightTrn01")!)
        let open = app.buttons["deep-link-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Night trains are making a comeback across Europe"].waitForExistence(timeout: 5))
        settle()
        capture(app, "10-deep-link-summary")

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 5))
        app.open(URL(string: "summarychip://s/N0rthB0und")!)
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["trip-more-menu"].waitForExistence(timeout: 10))
        settle(2)
        capture(app, "11-deep-link-trip")
    }

    // MARK: Helpers

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes"]
        // Portrait on iPad too: landscape screenshots come back sideways and cropped. The 13-inch
        // iPad is regular width either way, so it still shows the sidebar layout.
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["Why specialty roasters are buying their own farms"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func openTrip(_ app: XCUIApplication) {
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Northbound Japan")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-pane-picker"].firstMatch.waitForExistence(timeout: 10))
    }

    /// The pane picker shows icons on iPhone and titles on iPad; both are labelled with the title.
    @MainActor private func selectPane(_ app: XCUIApplication, _ title: String) {
        let picker = app.descendants(matching: .any)["trip-pane-picker"].firstMatch
        let button = picker.buttons[title].exists ? picker.buttons[title] : app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor private func chatInput(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["chat-input"]
        return field.exists ? field : app.textViews["chat-input"].exists ? app.textViews["chat-input"] : field
    }

    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.swipeDown(velocity: .slow)
    }

    /// Swipes the page up until `element` is on screen.
    @MainActor private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp(velocity: .slow)
        }
    }

    /// Lets images, maps and transitions finish before the capture.
    private func settle(_ seconds: UInt32 = 1) {
        sleep(seconds)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "screenshot__\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
