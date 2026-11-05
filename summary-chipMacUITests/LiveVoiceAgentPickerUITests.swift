import XCTest

/// The voice agent picker opens from the composer and remembers the last pick across launches.
nonisolated final class LiveVoiceAgentPickerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES", "-chatPanelVisible", "NO"]
        app.launch()
        app.activate()
        let toggle = app.descendants(matching: .any)["toggle-chat-panel"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.2)
        toggle.click()
        XCTAssertTrue(pickerButton(app).waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    @MainActor private func pickerButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat-voice-agent"].firstMatch
    }

    @MainActor private func row(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["voice-agent-\(name)"].firstMatch
    }

    @MainActor private func openSheet(_ app: XCUIApplication) {
        pickerButton(app).click()
        XCTAssertTrue(row("chippy", app).waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func closeSheet(_ app: XCUIApplication) {
        app.descendants(matching: .any)["voice-agent-done"].firstMatch.click()
        XCTAssertTrue(row("chippy", app).waitForNonExistence(timeout: 10))
    }

    @MainActor func testPickerListsEveryAgentAndKeepsTheCloudVoiceAvailable() {
        let app = launch()
        openSheet(app)
        XCTAssertTrue(row("claudeCode", app).exists)
        XCTAssertTrue(row("codex", app).exists)
        row("chippy", app).click()
        add(XCTAttachment(screenshot: app.screenshot()))
        closeSheet(app)
        XCTAssertEqual(pickerButton(app).value as? String, "Chippy")
    }

    @MainActor func testLastPickIsRememberedAcrossLaunches() throws {
        var app = launch()
        openSheet(app)
        let agent = row("codex", app)
        // The row turns enabled once the runner reports the install.
        let installed = NSPredicate(format: "isEnabled == YES")
        let wait = XCTNSPredicateExpectation(predicate: installed, object: agent)
        guard XCTWaiter.wait(for: [wait], timeout: 20) == .completed else {
            throw XCTSkip("Codex isn't installed on this machine.")
        }
        addTeardownBlock { @MainActor in
            // Leave the machine on the default for whatever runs next.
            let cleanup = self.launch()
            self.openSheet(cleanup)
            self.row("chippy", cleanup).click()
            self.closeSheet(cleanup)
            cleanup.terminate()
        }
        agent.click()
        Thread.sleep(forTimeInterval: 0.5)
        add(XCTAttachment(screenshot: app.screenshot()))
        closeSheet(app)
        XCTAssertEqual(pickerButton(app).value as? String, "Codex")
        app.terminate()

        app = launch()
        XCTAssertEqual(pickerButton(app).value as? String, "Codex")
        app.terminate()
    }

    @MainActor func testModelPickerAppearsOnlyForLocalAgents() throws {
        let app = launch()
        defer { app.terminate() }
        openSheet(app)
        let model = app.descendants(matching: .any)["voice-agent-model"].firstMatch
        row("chippy", app).click()
        XCTAssertTrue(model.waitForNonExistence(timeout: 5))
        let agent = row("codex", app)
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == YES"), object: agent)
        guard XCTWaiter.wait(for: [wait], timeout: 20) == .completed else {
            throw XCTSkip("Codex isn't installed on this machine.")
        }
        agent.click()
        XCTAssertTrue(model.waitForExistence(timeout: 10), app.debugDescription)
        // Give Codex time to answer, so the screenshot shows its real list.
        Thread.sleep(forTimeInterval: 5)
        model.click()
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Voice agent model picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey(.escape, modifierFlags: [])
        row("chippy", app).click()
        XCTAssertTrue(model.waitForNonExistence(timeout: 5))
        closeSheet(app)
    }

    @MainActor func testVoiceModelBrowserHasSidebarReadmeAndDownloadSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES", "-chatPanelVisible", "NO"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let settings = app.descendants(matching: .any)["mac-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.click()
        let manage = app.buttons["voice-model-settings"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.click()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("Kokoro-82M-bf16")
        let model = app.staticTexts["Kokoro-82M-bf16"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 30))
        model.click()
        let details = app.radioButtons["Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        details.click()
        XCTAssertTrue(app.staticTexts["Download size"].waitForExistence(timeout: 30))
        let sidebar = app.descendants(matching: .any)["voice-model-sidebar"].firstMatch
        let detail = app.descendants(matching: .any)["voice-model-detail"].firstMatch
        XCTAssertLessThan(sidebar.frame.midX, detail.frame.midX)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Hugging Face voice model browser"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
