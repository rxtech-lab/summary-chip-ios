import XCTest

nonisolated final class MacNavigationUITests: XCTestCase {
    @MainActor func testPlannedPodcastsLeaveLibraryChipsVisible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-podcast-plans", "-chatPanelVisible", "NO",
                               "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.activate()
        let draft = app.buttons["planned-podcast-preview-plan"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let chip = app.buttons["summary-card-s-coffee"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(draft.frame.height, 0)
        XCTAssertGreaterThan(chip.frame.height, 0)
        XCTAssertGreaterThan(chip.frame.minY, draft.frame.minY)
        XCTAssertLessThan(chip.frame.maxY, app.windows.firstMatch.frame.maxY)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "56 years")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Planned draft and library chips together"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let draftY = draft.frame.minY
        app.activate()
        app.scrollViews["summary-card-feed"].scroll(byDeltaX: 0, deltaY: -250)
        if draft.exists {
            XCTAssertLessThan(draft.frame.minY, draftY, "Drafts must scroll with the posts")
        }
    }

    @MainActor func testConfirmingPlanDoesNotReopenReview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-podcast-plans", "-chatPanelVisible", "NO",
                               "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.activate()
        let draft = app.buttons["planned-podcast-preview-plan"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        let confirm = app.buttons["podcast-plan-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "Confirmation must close review and start generation")
        XCTAssertTrue(draft.waitForNonExistence(timeout: 5), "A confirmed draft must leave the feed")
        XCTAssertFalse(app.buttons["Use This Script and Storyboard"].exists, "Mac must not ask for a second confirmation")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Confirmed plan opens podcast"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testContextMenuDeletesBackgroundJobHistoryAfterConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "-chatPanelVisible", "NO", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let actions = app.descendants(matching: .any)["library-actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.click()
        app.menuItems["Background Jobs"].click()
        let row = app.descendants(matching: .any)["background-job-preview-video-job"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        app.menuItems["Delete Job Log"].click()
        app.buttons["Cancel"].click()
        XCTAssertTrue(row.exists)
        row.rightClick()
        app.menuItems["Delete Job Log"].click()
        app.buttons["Delete Job Log"].click()
        XCTAssertTrue(app.staticTexts["No Background Jobs"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        app.buttons["Done"].click()
        actions.click()
        app.menuItems["Background Jobs"].click()
        XCTAssertTrue(app.staticTexts["No Background Jobs"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
    }

    @MainActor
    func testSettingsReopensWelcomeAndNewFeatures() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mac", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mac-sidebar"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["mac-settings"].click()

        let welcome = app.buttons["settings-welcome"]
        let features = app.buttons["settings-features"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        XCTAssertTrue(features.exists)

        welcome.click()
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Just ask Siri"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))

        features.click()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Connect your AI agents"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Meet your Trip Diary"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Research papers, in LaTeX"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Turn your chips into a podcast"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Your day, in a short recap"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Find the stories that stand out"].waitForExistence(timeout: 5))
        app.buttons["Got it"].click()
        XCTAssertTrue(features.waitForExistence(timeout: 5))

        welcome.click()
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
        XCTAssertTrue(features.waitForExistence(timeout: 5))
        features.click()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
    }

    @MainActor
    func testSidebarAndDedicatedCreationSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-mac"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mac-sidebar"].waitForExistence(timeout: 10))

        app.descendants(matching: .any)["library-actions"].firstMatch.click()
        app.menuItems["Search"].click()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        app.textFields["search-input"].typeText("summary")
        app.buttons["close-search"].click()
        XCTAssertFalse(app.textFields["search-input"].exists)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertFalse(app.textFields["search-input"].exists)
        app.descendants(matching: .any)["mac-settings"].click()
        XCTAssertTrue(app.buttons["settings-welcome"].waitForExistence(timeout: 5))
        app.buttons["settings-welcome"].click()
        XCTAssertTrue(app.buttons["education-next"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["new-summary-input"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["generate-summary"].isEnabled)
        app.textFields["new-summary-input"].click()
        app.textFields["new-summary-input"].typeText("A short piece of text to summarise.")
        XCTAssertTrue(app.buttons["generate-summary"].isEnabled)
        app.buttons["Choose a PDF…"].click()
        XCTAssertTrue(app.descendants(matching: .any)["open-panel"].waitForExistence(timeout: 5))
        app.buttons["CancelButton"].click()
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.textFields["new-summary-input"].exists)
    }

    @MainActor
    func testLibraryMenuAndScrollPositionAfterDetail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes", "--preview-paged-feed", "-chatPanelVisible", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let actions = app.descendants(matching: .any)["library-actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["background-jobs-toolbar"].exists)
        actions.click()
        XCTAssertTrue(app.menuItems["Search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Filter"].exists)
        XCTAssertTrue(app.menuItems["Background Jobs"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let feed = app.scrollViews["summary-card-feed"]
        let card = app.descendants(matching: .any)["summary-card-scroll-24"].firstMatch
        for _ in 0..<20 {
            if card.exists && card.isHittable { break }
            feed.scroll(byDeltaX: 0, deltaY: -450)
        }
        XCTAssertTrue(card.exists && card.isHittable, app.debugDescription)
        for _ in 0..<2 {
            let previousY = card.frame.minY
            card.click()
            XCTAssertTrue(app.buttons["summary-like"].firstMatch.waitForExistence(timeout: 5))
            let back = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label IN %@", ["Back", "Go Back"])).firstMatch
            if back.exists { back.click() } else { app.typeKey("[", modifierFlags: .command) }
            XCTAssertTrue(actions.waitForExistence(timeout: 5))
            let returned = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            returned.name = "mac-returned-feed"
            returned.lifetime = .keepAlways
            add(returned)
            XCTAssertTrue(card.exists)
            XCTAssertEqual(card.frame.minY, previousY, accuracy: 12, app.debugDescription)
            XCTAssertTrue(card.isHittable)
        }
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "mac-feed-position-after-return"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWelcomeAdvancesOnMac() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-education"]
        app.launch()
        let next = app.buttons["education-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["From Safari to a summary"].exists)
        next.click()
        XCTAssertTrue(app.staticTexts["Just ask Siri"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertTrue(app.staticTexts["Share on your terms"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertTrue(app.staticTexts["Your next summary, with Siri"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertTrue(app.staticTexts["Connect your AI agents"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertTrue(app.staticTexts["Meet your Trip Diary"].waitForExistence(timeout: 3))
        next.click()
        XCTAssertFalse(next.exists)
    }
}
