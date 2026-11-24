import XCTest

nonisolated final class FlowcyModelPickerUITests: XCTestCase {
    @MainActor func testFlowcyUsageInSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-retry-model-usage", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
        XCTAssertTrue(app.staticTexts["Why specialty roasters are buying their own farms"].waitForExistence(timeout: 15))
        if UIDevice.current.userInterfaceIdiom == .pad {
            let settings = app.cells.containing(.staticText, identifier: "mac-settings").firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 12))
            settings.tap()
        } else {
            app.tabBars.buttons["Settings"].tap()
        }
        let retry = app.buttons["flowcy-usage-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        let five = app.descendants(matching: .any)["flowcy-usage-agent_cost_5h"].firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 10))
        XCTAssertTrue(five.label.contains("25%"))
        let week = app.descendants(matching: .any)["flowcy-usage-agent_cost_7d"].firstMatch
        let month = app.descendants(matching: .any)["flowcy-usage-agent_cost_30d"].firstMatch
        XCTAssertTrue(week.label.contains("14%"))
        XCTAssertTrue(month.label.contains("Percentage unavailable"))
        for row in [five, week, month] {
            XCTAssertFalse(row.label.contains("$") || row.label.contains("USD") || row.label.contains("Resets"))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Flowcy model usage in Settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testChoosingACloudModelFromChat() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-chatPanelVisible", "NO", "-AppleLanguages", "(en)"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let toggle = app.buttons["toggle-chat-panel"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 15))
            toggle.tap()
        } else {
            let tab = app.tabBars.buttons["Chat"]
            XCTAssertTrue(tab.waitForExistence(timeout: 15))
            tab.tap()
        }
        let composer = app.descendants(matching: .any)["chat-composer"].firstMatch
        let picker = composer.buttons["chat-ai-models"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let attach = composer.buttons["chat-attach-files"]
        let input = composer.descendants(matching: .any)["chat-input"].firstMatch
        let voice = composer.buttons["chat-voice-start"]
        let send = composer.buttons["chat-send"]
        XCTAssertTrue(attach.isHittable && input.isHittable && voice.isHittable)
        XCTAssertLessThanOrEqual(attach.frame.maxX, input.frame.minX)
        XCTAssertEqual(attach.frame.midY, input.frame.midY, accuracy: 5)
        XCTAssertLessThan(input.frame.maxY, picker.frame.midY)
        XCTAssertEqual(picker.frame.midY, voice.frame.midY, accuracy: 3)
        XCTAssertEqual(voice.frame.midY, send.frame.midY, accuracy: 3)
        XCTAssertFalse(send.isEnabled)
        input.tap()
        input.typeText("Keep my draft")
        XCTAssertTrue(send.isEnabled)
        picker.tap()
        let model = app.buttons["flowcy-model-fixture/chat"]
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["chat-agent-provider"].exists)
        model.tap()
        XCTAssertTrue(model.wait(for: \.isSelected, toEqual: true, timeout: 5))
        app.buttons["Done"].tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Preview Chat"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, "Keep my draft")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Two-row chat composer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        picker.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        XCTAssertTrue(model.isSelected)
        app.buttons["flowcy-model-automatic"].tap()
        XCTAssertTrue(app.buttons["flowcy-model-automatic"].wait(for: \.isSelected, toEqual: true, timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertEqual(picker.value as? String, "Automatic")
        attach.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "Keep my draft")
    }
}
