import XCTest

nonisolated final class ChatScrollDiagUITests: XCTestCase {
    @MainActor
    private func sample(_ app: XCUIApplication, label: String, seconds: TimeInterval, tag: String) {
        var last = ""
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let q = app.staticTexts.matching(identifier: label)
            var ys: [Int] = []
            for i in 0..<q.count {
                let e = q.element(boundBy: i)
                if e.exists { ys.append(Int(e.frame.minY)) }
            }
            let s = ys.map(String.init).joined(separator: ",")
            if s != last { print("DIAG \(tag) t=\(String(format: "%.2f", Date().timeIntervalSince(start))) y=[\(s)]") }
            last = s
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    @MainActor
    func testDiagSamplePositions() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--preview-chat-stream"]
        app.launch()
        app.buttons["What did I save about AI this week?"].tap()
        sample(app, label: "Streaming layout check", seconds: 22, tag: "turn1")
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 3))
        let field = app.textFields["chat-input"].exists ? app.textFields["chat-input"] : app.textViews["chat-input"]
        field.tap()
        field.typeText("Second question")
        app.buttons["Send"].tap()
        sample(app, label: "Streaming layout check", seconds: 22, tag: "turn2")
    }
}
