import XCTest

/// The agent panel's toolbar toggle never changes the navigation sidebar on macOS.
nonisolated final class SideAgentPanelUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testOpeningPanelKeepsClosedSidebarClosed() {
        assertTogglingPanel(toOpen: true, sidebarOpen: false)
    }

    @MainActor func testOpeningPanelKeepsOpenSidebarOpen() {
        assertTogglingPanel(toOpen: true, sidebarOpen: true)
    }

    @MainActor func testClosingPanelKeepsClosedSidebarClosed() {
        assertTogglingPanel(toOpen: false, sidebarOpen: false)
    }

    @MainActor func testClosingPanelKeepsOpenSidebarOpen() {
        assertTogglingPanel(toOpen: false, sidebarOpen: true)
    }

    @MainActor func testDocumentOpensPanelFromToolbarToggle() {
        let app = launch()
        setPanel(false, in: app)
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Why specialty roasters")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.click()
        settle()
        XCTAssertFalse(app.buttons["ask-summary"].exists)
        toggle(app).click()
        settle()
        XCTAssertTrue(panel(app).exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat-context-document"].waitForExistence(timeout: 5))
    }

    @MainActor private func assertTogglingPanel(toOpen: Bool, sidebarOpen: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let app = launch()
        setSidebar(sidebarOpen, in: app)
        setPanel(!toOpen, in: app)
        XCTAssertEqual(isSidebarOpen(app), sidebarOpen, "sidebar before", file: file, line: line)

        toggle(app).click()
        settle()
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "panel-\(toOpen)-sidebar-\(sidebarOpen)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertEqual(panel(app).exists, toOpen, "the toggle changes the panel", file: file, line: line)
        XCTAssertEqual(isSidebarOpen(app), sidebarOpen, "the sidebar stays as it was", file: file, line: line)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES", "-chatPanelVisible", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(toggle(app).waitForExistence(timeout: 20), app.debugDescription)
        settle()
        return app
    }

    @MainActor private func toggle(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["toggle-chat-panel"].firstMatch
    }

    @MainActor private func panel(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["agent-panel"].firstMatch
    }

    @MainActor private func isSidebarOpen(_ app: XCUIApplication) -> Bool {
        let row = app.descendants(matching: .any)["sidebar-likes"].firstMatch
        return row.exists && row.isHittable
    }

    @MainActor private func setPanel(_ open: Bool, in app: XCUIApplication) {
        if panel(app).exists != open {
            toggle(app).click()
            settle()
        }
        XCTAssertEqual(panel(app).exists, open)
    }

    @MainActor private func setSidebar(_ open: Bool, in app: XCUIApplication) {
        guard isSidebarOpen(app) != open else { return }
        app.typeKey("s", modifierFlags: [.command, .control])
        settle()
        XCTAssertEqual(isSidebarOpen(app), open)
    }

    @MainActor private func settle() {
        Thread.sleep(forTimeInterval: 1.2)
    }
}
