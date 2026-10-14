import XCTest

/// Captures the main screens on iPhone and iPad for the PR screenshot comment
/// (.github/workflows/screenshots.yaml). Each screen is its own test so one that fails to load does
/// not cost the others their screenshots. Every screen is reached in the app itself, running against
/// the `--preview-likes` fixture (iPhone in portrait, iPad in landscape); attachments named
/// `screenshot__<name>` are exported by scripts/ci/export-screenshots.sh.
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

    @MainActor func test04bTripPlans() {
        let app = launch()
        openTrip(app)
        let diary = app.descendants(matching: .any)["trip-day-strip"].firstMatch
        XCTAssertTrue(diary.waitForExistence(timeout: 10))
        if !isPad {
            let grabber = diary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -30))
            grabber.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
            settle()
        }
        // Day 3 has two routes; the diary starts on the first.
        diary.buttons.element(boundBy: 2).tap()
        let menu = app.buttons["trip-plan-menu-plan-d3"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Matsushima side trip"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Yamadera mountain temple"].exists)
        settle()
        capture(app, "04b-trip-plans-route-1")

        menu.tap()
        let yamadera = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Route 2 · Yamadera")).firstMatch
        XCTAssertTrue(yamadera.waitForExistence(timeout: 5))
        settle()
        capture(app, "04c-trip-plans-menu")
        yamadera.tap()
        XCTAssertTrue(app.staticTexts["Yamadera mountain temple"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Matsushima side trip"].exists)
        settle()
        capture(app, "04d-trip-plans-route-2")
        app.buttons["trip-day-details-d3-yamadera"].firstMatch.tap()
        let plans = app.buttons["trip-day-detail-plans"].firstMatch
        XCTAssertTrue(plans.waitForExistence(timeout: 5))
        settle()
        capture(app, "04e-day-sheet")
        plans.tap()
        let matsushima = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Route 1")).firstMatch
        XCTAssertTrue(matsushima.waitForExistence(timeout: 5))
        settle()
        capture(app, "04f-day-sheet-menu")
        matsushima.tap()
        XCTAssertTrue(app.staticTexts["Matsushima side trip"].waitForExistence(timeout: 5))
        settle()
        capture(app, "04g-day-sheet-route-1")
    }

    /// Play mode: the tour opens from More, writes its scenes, and steps through them.
    @MainActor func test04cTripTour() {
        let app = launch()
        openTrip(app)
        let more = app.buttons["trip-more-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let play = app.buttons["trip-play-tour"].firstMatch
        XCTAssertFalse(play.exists)
        more.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        capture(app, "04c-trip-tour-menu")
        play.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-tour"].firstMatch.waitForExistence(timeout: 10))
        let details = app.buttons["Show Details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        XCTAssertTrue(app.staticTexts["North by rail"].waitForExistence(timeout: 10))
        settle(4)
        capture(app, "04c-trip-tour-intro")
        let next = app.buttons["Next Stop"].firstMatch
        for _ in 0..<2 { next.tap() }
        XCTAssertTrue(app.staticTexts["A night in Tokyo"].waitForExistence(timeout: 5))
        settle(5)
        capture(app, "04d-trip-tour-stay")
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["Close Tour"].firstMatch.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertFalse(play.exists)
        more.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
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

    /// Custom JSON gallery images appear in the tour even when the saved place has no photos.
    @MainActor func test04dTripTourPhotos() {
        let app = launch(extraArguments: ["--preview-tour-photos"])
        openTrip(app)
        let more = app.buttons["trip-more-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["trip-play-tour"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-tour"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Next Stop"].firstMatch.tap()
        let carousel = app.descendants(matching: .any)["trip-tour-photo-carousel"].firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 20))
        settle(2)
        capture(app, "04h-tour-photo-popover")
        // The second image appears as narration progresses, without touching the carousel.
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 30))
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["Previous Photo"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 5))
        app.buttons["Next Photo"].firstMatch.tap()
        settle()
        capture(app, "04i-tour-photo-carousel")
        app.buttons["Preview photo 2"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-photo-viewer"].firstMatch.waitForExistence(timeout: 5))
        settle()
        capture(app, "04j-tour-photo-sheet")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Play"].firstMatch.tap()
        app.buttons["Preview photo 2"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-photo-viewer"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
    }

    /// A museum named in the itinerary can move the camera beyond its saved city-level stop.
    @MainActor func test04eTripTourLandmark() {
        let app = launch(extraArguments: ["--preview-tour-photos", "--preview-tour-landmarks"])
        openTrip(app)
        let more = app.buttons["trip-more-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["trip-play-tour"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-tour"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Next Stop"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Nezu Museum"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["trip-tour-photo-carousel"].firstMatch.exists)
        settle(8)
        capture(app, "04k-tour-museum-map")
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

    // MARK: Paper

    /// The paper from the library: the editor (beside its PDF on iPad), then the native reader with
    /// its reviewed passages, figures and a TikZ drawing.
    @MainActor func test12Paper() {
        let app = launch()
        openPaper(app)
        if isPad {
            selectPreviewMode(app, "PDF")
            XCTAssertTrue(app.descendants(matching: .any)["paper-save-status"].firstMatch.waitForExistence(timeout: 10))
            settle(3)
        } else {
            settle(2)
        }
        capture(app, "12-paper-editor")

        showReader(app)
        settle(2)
        capture(app, "12b-paper-reader")
        // The LaTeX-drawn figure sits below the table; the reader builds it once it scrolls into view.
        let drawing = app.buttons["A diagram."].firstMatch
        for _ in 0..<10 where !drawing.exists {
            app.scrollViews["paper-reader"].swipeUp(velocity: .slow)
        }
        XCTAssertTrue(drawing.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Growth over five years."].exists)
        settle(2)
        capture(app, "12c-paper-reader-figures")
    }

    /// Select text in the reader → Add Review → a comment for the agent.
    @MainActor func test14PaperReviewCompose() {
        let app = launch()
        openPaper(app)
        showReader(app)
        let paragraph = app.textViews["paper-reader-paragraph"].firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        // Double-tapping a word selects it and opens the selection menu, which starts with Add Review.
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).doubleTap()
        let addReview = app.menuItems["Add Review"]
        XCTAssertTrue(addReview.waitForExistence(timeout: 5))
        addReview.tap()
        XCTAssertTrue(app.navigationBars["Add Review"].waitForExistence(timeout: 5))
        let comment = app.textFields["paper-review-comment"].exists ? app.textFields["paper-review-comment"] : app.textViews["paper-review-comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        comment.typeText("Add Fermat's own note on the margin here.")
        settle()
        capture(app, "14-paper-review-compose")
    }

    /// The paper's reviews, then the change the agent made for the finished one.
    @MainActor func test15PaperReviews() {
        let app = launch()
        openPaper(app)
        showReader(app)
        let button = app.buttons["paper-reviews-button"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.navigationBars["Reviews"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ready to Review"].waitForExistence(timeout: 5))
        settle()
        capture(app, "15-paper-reviews")

        let row = app.buttons["paper-review-paper-addressed"].firstMatch
        (row.exists ? row : app.staticTexts["Say what literate programming means before using the term."].firstMatch).tap()
        XCTAssertTrue(app.navigationBars["Review Changes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Mark as Finished"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "an essay written for people")).firstMatch.waitForExistence(timeout: 10))
        settle()
        capture(app, "16-paper-review-diff")
    }

    // MARK: Helpers

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-likes"] + extraArguments
        // iPad is captured in landscape, as it is mostly used; `capture` turns the image upright.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
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

    /// Opens the fixture's paper from the library.
    @MainActor private func openPaper(_ app: XCUIApplication) {
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Reading Papers Natively")).firstMatch
        for _ in 0..<6 where !(card.exists && card.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["paper-file-menu"].firstMatch.waitForExistence(timeout: 10))
    }

    /// The paper's preview in the native reader: beside the editor on iPad, in the PDF sheet on iPhone.
    @MainActor private func showReader(_ app: XCUIApplication) {
        if !isPad {
            app.buttons["paper-show-pdf"].firstMatch.tap()
        }
        selectPreviewMode(app, "Reader")
        XCTAssertTrue(app.scrollViews["paper-reader"].waitForExistence(timeout: 10))
    }

    /// The preview mode is remembered between launches, so each test picks the one it needs.
    @MainActor private func selectPreviewMode(_ app: XCUIApplication, _ title: String) {
        let picker = app.segmentedControls["paper-preview-mode"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let button = picker.buttons[title].exists ? picker.buttons[title] : app.buttons[title].firstMatch
        button.tap()
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
        let attachment: XCTAttachment
        if isPad, XCUIDevice.shared.orientation.isLandscape, let png = landscape(XCUIScreen.main.screenshot().image).pngData() {
            attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        } else {
            attachment = XCTAttachment(screenshot: app.screenshot())
        }
        attachment.name = "screenshot__\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The simulator can hand the screen back in its portrait orientation while the app is in
    /// landscape (the picture sideways); this turns it upright and bakes the orientation into the
    /// pixels, which PNG data doesn't carry.
    @MainActor private func landscape(_ image: UIImage) -> UIImage {
        var upright = image
        if image.size.height > image.size.width, let cgImage = image.cgImage {
            // Landscape left has the home edge on the right, so the interface's top runs along the
            // portrait screen's right edge.
            let orientation: UIImage.Orientation = XCUIDevice.shared.orientation == .landscapeRight ? .right : .left
            upright = UIImage(cgImage: cgImage, scale: image.scale, orientation: orientation)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = upright.scale
        return UIGraphicsImageRenderer(size: upright.size, format: format).image { _ in
            upright.draw(in: CGRect(origin: .zero, size: upright.size))
        }
    }
}
