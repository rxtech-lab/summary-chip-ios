import Foundation
import XCTest

/// Set TEST_RUNNER_RESUME_HTTP_E2E=1 with the isolated E2E API on 3180 and issuer on 3181.
nonisolated final class ResumeUITests: XCTestCase {
    @MainActor func testCompanyEditSurvivesRelaunchAndLeavesBaseIntact() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RESUME_HTTP_E2E"] == "1", "Requires loopback résumé E2E API and test issuer")
        continueAfterFailure = false
        let issuer = URL(string: "http://127.0.0.1:3181/token")!
        let auth = try await request(issuer, body: ["sub":"resume-local-owner", "clientId":"e2e-client"])
        let token = try XCTUnwrap(auth["access_token"] as? String)
        let root = URL(string: "http://127.0.0.1:3180/api/v1/resumes")!
        let created = try await request(root, token: token, body: [
            "title":"Native verification", "language":"en", "idempotencyKey":UUID().uuidString,
            "document":["version":1, "candidateName":"Mariam", "links":[], "sections":[]] as [String:Any]
        ])
        let family = try XCTUnwrap(created["familyId"] as? String)
        let variant = try await request(root.appending(path: family + "/variants"), token: token, body: [
            "language":"en", "company":"Atelier", "expectedRevisionToken":try XCTUnwrap(created["revisionToken"]),
            "idempotencyKey":UUID().uuidString
        ])
        let variantID = try XCTUnwrap(variant["variantId"] as? String)
        let app = XCUIApplication()
        app.launchArguments = ["--preview-resume-http", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        #if os(macOS)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO", "-SUEnableAutomaticChecks", "NO"]
        #endif
        app.launchEnvironment = ["RESUME_TEST_TOKEN":token, "RESUME_TEST_FAMILY":family]
        app.launch()
        app.activate()
        selectCompany(app)
        press(app.buttons["resume-edit"])
        let headline = app.textFields["resume-headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10), app.debugDescription)
        press(headline)
        headline.typeText("Engineer at Atelier")
        press(app.buttons["resume-save"])
        XCTAssertTrue(headline.waitForNonExistence(timeout: 12), app.debugDescription)
        let base = try await request(root.appending(path: family), token: token)
        XCTAssertNil((base["document"] as? [String:Any])?["headline"])
        let edited = try await request(root.appending(path: family).appending(queryItems: [.init(name:"variantId",value:variantID)]), token: token)
        XCTAssertEqual((edited["document"] as? [String:Any])?["headline"] as? String, "Engineer at Atelier")
        app.terminate()
        app.launch()
        app.activate()
        selectCompany(app)
        XCTAssertTrue(app.staticTexts["Engineer at Atelier"].waitForExistence(timeout: 12), app.debugDescription)
        verifyExportPreview(app, variantID: variantID)
        if ProcessInfo.processInfo.environment["RESUME_CHAT_E2E"] == "1" {
            try await verifyChatEdit(app, familyURL: root.appending(path: family), variantID: variantID, token: token)
        }
    }

    @MainActor private func verifyExportPreview(_ app: XCUIApplication, variantID: String) {
        let actions = app.descendants(matching: .any)["resume-actions"].firstMatch
        press(actions)
        let export = app.descendants(matching: .any)["resume-export"].firstMatch
        press(export)
        let company = app.buttons["export-company-" + variantID]
        XCTAssertTrue(company.waitForExistence(timeout: 8), app.debugDescription)
        press(company)
        press(app.buttons["Choose Template"])
        press(app.buttons["Preview PDF"])
        let preview = app.descendants(matching: .any)["paper-pdf"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 75), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pinned company PDF preview"
        shot.lifetime = .keepAlways
        add(shot)
        press(app.buttons["resume-export-close"])
    }

    @MainActor private func verifyChatEdit(_ app: XCUIApplication, familyURL: URL, variantID: String, token: String) async throws {
        press(app.descendants(matching: .any)["resume-actions"].firstMatch)
        press(app.descendants(matching: .any)["Agent Chat"].firstMatch)
        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        press(input)
        input.typeText("Change this company resume headline to exactly: Atelier Design Lead. Apply the edit now.")
        press(app.buttons["chat-send"])
        let editionURL = familyURL.appending(queryItems: [.init(name:"variantId",value:variantID)])
        var saved = false
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let response = try await request(editionURL, token: token)
            if (response["document"] as? [String:Any])?["headline"] as? String == "Atelier Design Lead" {
                saved = true; break
            }
        }
        XCTAssertTrue(saved, app.debugDescription)
        let freshBase = try await request(familyURL, token: token)
        XCTAssertNil((freshBase["document"] as? [String:Any])?["headline"])
    }

    @MainActor private func selectCompany(_ app: XCUIApplication) {
        let menu = app.descendants(matching: .any)["resume-company"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
        press(menu)
        #if os(macOS)
        let item = app.menuItems["Atelier"].firstMatch
        #else
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Atelier")).firstMatch
        #endif
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        press(item)
        XCTAssertTrue(app.buttons["resume-edit"].waitForExistence(timeout: 10))
    }

    @MainActor private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor private func request(_ url: URL, token: String? = nil, body: [String:Any]? = nil) async throws -> [String:Any] {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        XCTAssertTrue((200..<300).contains(code), "HTTP \(code) at \(url.path)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
    }
}
