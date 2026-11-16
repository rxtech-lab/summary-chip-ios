#if DEBUG
import Foundation
import SummaryKit
import SwiftUI

/// Offline UI validation uses the real detail/editor screens with an in-memory API.
struct TodoPreviewHost: View {
    @State private var environment: AppEnvironment = {
        let token = SharedTokenBundle(accessToken: "preview-token", refreshToken: nil, idToken: nil, expiresAt: .now.addingTimeInterval(86400), subject: "preview-user")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TodoPreviewProtocol.self]
        return AppEnvironment.live(configuration: .live(), vault: InMemoryTokenVault(token), session: URLSession(configuration: config), authenticationState: .signedIn)
    }()
    var body: some View {
        NavigationStack { TodoDetailView(environment: environment, id: "todo-preview") }
    }
}

nonisolated private final class TodoPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (status, body) = TodoPreviewStore.shared.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
nonisolated private final class TodoPreviewStore: @unchecked Sendable {
    static let shared = TodoPreviewStore()
    private let lock = NSLock()
    private var revision = 0
    private var document: TodoDocument = .init(title: "Today", description: "## Work\n\nResearch **Singapore investment opportunities** and prepare a short list.", deadline: .now.addingTimeInterval(3600), items: [
        .init(id: "research", title: "Search investors and accelerators", deadline: .now.addingTimeInterval(-3600)),
        .init(id: "coffee", title: "Buy snacks and coffee", deadline: .now.addingTimeInterval(1800)),
        .init(id: "app", title: "Build the voting app", deadline: .now.addingTimeInterval(7200), completed: true),
    ])
    func response(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            guard request.url?.path.contains("todo-lists") == true else { return (404, Data()) }
            if request.httpMethod == "PUT" {
                let data: Data
                if let body = request.httpBody { data = body }
                else if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    var result = Data()
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        result.append(buffer, count: count)
                    }
                    data = result
                } else { data = Data() }
                struct Update: Decodable { let document: TodoDocument; let revision: Int }
                if let update = try? SummaryJSON.decoder().decode(Update.self, from: data), update.revision == revision {
                    document = update.document; revision += 1
                } else { return (409, Data()) }
            }
            let content = (try? JSONSerialization.jsonObject(with: SummaryJSON.encoder().encode(document))) ?? [:]
            let result: [String: Any] = ["todoList": ["id": "todo-preview", "revision": revision, "document": content, "isOwner": true, "visibility": "private", "shareUrl": "https://example.com/s/todo", "updatedAt": "2026-11-16T00:00:00Z"]]
            return (200, (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        }
    }
}
#endif
