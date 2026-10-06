import Foundation
import Testing
@testable import SummaryKit

struct AppVersionTests {
    @Test func everyAPIRequestCarriesTheAppVersion() {
        let api = SummaryAPIClient(baseURL: URL(string: "https://version.test")!, tokenProvider: VersionTestToken())
        let request = api.request("/api/v1/trips")
        #expect(request.value(forHTTPHeaderField: "X-App-Platform") == AppVersion.platform)
        #expect(request.value(forHTTPHeaderField: "X-App-Version") == AppVersion.current)
        #expect(request.value(forHTTPHeaderField: "X-App-Build") == AppVersion.build)
    }

    @Test func updateRequiredErrorsCarryTheVersionToUpdateTo() throws {
        let body = Data("""
        {"error":{"code":"APP_UPDATE_REQUIRED","message":"Update","requestId":"r1",
          "details":{"feature":"trips","requiredVersion":"1.9.0","currentVersion":"1.8.0","updateUrl":"https://apps.apple.com/app/id1"}}}
        """.utf8)
        let response = HTTPURLResponse(url: URL(string: "https://version.test")!, statusCode: 426, httpVersion: nil, headerFields: nil)!
        #expect(throws: SummaryAPIError.self) { try SummaryAPIClient.validate(data: body, response: response) }
        do {
            try SummaryAPIClient.validate(data: body, response: response)
        } catch let error as SummaryAPIError {
            let requirement = try #require(error.appUpdateRequirement)
            #expect(requirement.requiredVersion == "1.9.0")
            #expect(requirement.feature == "trips")
            #expect(requirement.updateURL == URL(string: "https://apps.apple.com/app/id1"))
            #expect(error.errorDescription?.contains("1.9.0") == true)
        }
    }

    @Test func otherErrorsDoNotAskForAnUpdate() {
        let error = SummaryAPIError.server(status: 404, body: APIErrorBody(code: "NOT_FOUND", message: "Missing"))
        #expect(error.appUpdateRequirement == nil)
    }
}

private struct VersionTestToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}
