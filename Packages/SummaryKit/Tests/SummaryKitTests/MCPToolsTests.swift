import Foundation
import Testing
@testable import SummaryKit

struct MCPToolsTests {
    @Test func loadsLiveToolsWithAppAuthenticationAndWithoutLocalCaching() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPToolsProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://mcp-tools.test")!, tokenProvider: MCPToolsToken(),
            session: URLSession(configuration: configuration))

        let tools = try await api.mcpTools()
        #expect(tools == [MCPTool(name: "new_server_tool", title: "New Server Tool", description: "A live server description."),
            MCPTool(name: "minimal_tool")])
        #expect(tools.map(\.id) == ["new_server_tool", "minimal_tool"])
    }
}

private struct MCPToolsToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "app-token" }
}

private final class MCPToolsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp-tools.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        #expect(request.url?.path == "/api/v1/mcp/tools")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer app-token")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let json = """
        {"items":[{"name":"new_server_tool","title":"New Server Tool","description":"A live server description."},
        {"name":"minimal_tool"}]}
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
