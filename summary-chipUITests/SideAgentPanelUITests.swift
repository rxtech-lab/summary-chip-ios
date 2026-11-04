import XCTest

/// The agent panel is a trailing column on every regular-width layout: opening or closing it never
/// changes the navigation sidebar, and one toolbar toggle controls it on every page.
nonisolated final class SideAgentPanelUITests: XCTestCase {
    /// Every per-document agent button; none of them shows where the panel's toggle exists.
    private static let documentAgentButtons = ["ask-summary", "trip-agent", "graph-agent", "mini-app-agent"]

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Sidebar stays as it was

    @MainActor func testOpeningPanelKeepsClosedSidebarClosed() throws {
        try assertTogglingPanel(toOpen: true, keepsSidebarOpen: false)
    }

    @MainActor func testOpeningPanelKeepsOpenSidebarOpen() throws {
        try assertTogglingPanel(toOpen: true, keepsSidebarOpen: true)
    }

    @MainActor func testClosingPanelKeepsClosedSidebarClosed() throws {
        try assertTogglingPanel(toOpen: false, keepsSidebarOpen: false)
    }

    @MainActor func testClosingPanelKeepsOpenSidebarOpen() throws {
        try assertTogglingPanel(toOpen: false, keepsSidebarOpen: true)
    }

    // MARK: Document pages

    @MainActor func testSummaryOpensPanelFromToolbarToggle() throws {
        try assertDocumentUsesPanelToggle(title: "Why specialty roasters are buying their own farms")
    }

    @MainActor func testTripOpensPanelFromToolbarToggle() throws {
        try assertDocumentUsesPanelToggle(title: "Northbound Japan")
    }

    @MainActor func testPaperOpensPanelFromToolbarToggle() throws {
        try assertDocumentUsesPanelToggle(title: "Reading Papers Natively")
    }

    @MainActor func testGraphOpensPanelFromToolbarToggle() throws {
        try assertDocumentUsesPanelToggle(title: "Computing Pioneers", extraArguments: ["--preview-graph-chip"])
    }

    // MARK: Helpers

    @MainActor private func assertTogglingPanel(toOpen: Bool, keepsSidebarOpen sidebarOpen: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let app = try launch(orientation)
            setSidebar(sidebarOpen, in: app)
            setPanel(!toOpen, in: app)
            let label = "\(orientation == .portrait ? "portrait" : "landscape")"
            XCTAssertEqual(isSidebarOpen(app), sidebarOpen, "\(label): sidebar before", file: file, line: line)

            togglePanel(in: app)
            capture(app, "\(label)-panel-\(toOpen)-sidebar-\(sidebarOpen)")

            XCTAssertEqual(panel(app).exists, toOpen, "\(label): the toggle changes the panel", file: file, line: line)
            XCTAssertEqual(isSidebarOpen(app), sidebarOpen, "\(label): the sidebar stays as it was", file: file, line: line)
            app.terminate()
        }
    }

    @MainActor private func assertDocumentUsesPanelToggle(title: String, extraArguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) throws {
        let app = try launch(.landscapeLeft, extraArguments: extraArguments)
        setPanel(false, in: app)
        open(title, in: app)
        settle()
        capture(app, "\(title) closed")

        for button in Self.documentAgentButtons {
            XCTAssertFalse(app.buttons[button].exists, "\(title) must not show \(button)", file: file, line: line)
        }
        togglePanel(in: app)
        capture(app, "\(title) open")
        XCTAssertTrue(panel(app).exists, "\(title): the toggle opens the panel", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["chat-context-document"].waitForExistence(timeout: 5),
                      "\(title): the panel talks about the open document", file: file, line: line)
        togglePanel(in: app)
        XCTAssertFalse(panel(app).exists, "\(title): the toggle closes the panel", file: file, line: line)
    }

    @MainActor private func launch(_ orientation: UIDeviceOrientation, extraArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        app.launch()
        XCUIDevice.shared.orientation = orientation
        try XCTSkipUnless(toggle(app).waitForExistence(timeout: 15), "Compact layouts use tabs and sheets")
        settle()
        return app
    }

    @MainActor private func toggle(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["toggle-chat-panel"].firstMatch
    }

    @MainActor private func panel(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["agent-panel"].firstMatch
    }

    @MainActor private func isSidebarOpen(_ app: XCUIApplication) -> Bool {
        let sidebar = app.descendants(matching: .any)["sidebar-likes"].firstMatch
        return sidebar.exists && sidebar.isHittable
    }

    @MainActor private func togglePanel(in app: XCUIApplication) {
        toggle(app).tap()
        settle()
    }

    @MainActor private func setPanel(_ open: Bool, in app: XCUIApplication) {
        if panel(app).exists != open { togglePanel(in: app) }
        XCTAssertEqual(panel(app).exists, open)
    }

    @MainActor private func setSidebar(_ open: Bool, in app: XCUIApplication) {
        guard isSidebarOpen(app) != open else { return }
        let button = app.buttons.matching(NSPredicate(format: "label IN %@", ["Hide Sidebar", "Show Sidebar"])).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
        settle()
        XCTAssertEqual(isSidebarOpen(app), open)
    }

    @MainActor private func open(_ title: String, in app: XCUIApplication) {
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        for _ in 0..<6 where !(card.exists && card.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5), title)
        card.tap()
    }

    @MainActor private func settle() {
        Thread.sleep(forTimeInterval: 1.2)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
