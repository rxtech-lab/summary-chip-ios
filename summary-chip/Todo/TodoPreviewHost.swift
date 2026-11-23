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
    private var tickets: [String: CreateUploadRequest] = [:]
    private var receivedUploads: Set<String> = []
    private var imagePreviews: [String: URL] = [:]
    private var document: TodoDocument = .init(title: "Today", description: "## Work\n\nResearch **Singapore investment opportunities** and prepare a short list.", deadline: .now.addingTimeInterval(3600), items: [
        .init(id: "research", title: "Search investors and accelerators", deadline: .now.addingTimeInterval(-3600)),
        .init(id: "coffee", title: "Buy snacks and coffee", deadline: .now.addingTimeInterval(1800)),
        .init(id: "app", title: "Build the voting app", deadline: .now.addingTimeInterval(7200), completed: true),
    ])
    func response(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            if let response = attachmentResponse(request) { return response }
            guard request.url?.path.contains("todo-lists") == true else { return (404, Data()) }
            if request.httpMethod == "PUT" {
                struct Update: Decodable { let document: TodoDocument; let revision: Int }
                if let update = try? SummaryJSON.decoder().decode(Update.self, from: body(of: request)), update.revision == revision {
                    document = update.document; revision += 1
                } else { return (409, Data()) }
            }
            let content = (try? JSONSerialization.jsonObject(with: SummaryJSON.encoder().encode(document))) ?? [:]
            let result: [String: Any] = ["todoList": ["id": "todo-preview", "revision": revision, "document": content, "isOwner": true, "visibility": "private", "shareUrl": "https://example.com/s/todo", "updatedAt": "2026-11-16T00:00:00Z"]]
            return (200, (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        }
    }

    private func attachmentResponse(_ request: URLRequest) -> (Int, Data)? {
        guard let url = request.url else { return nil }
        if url.path == "/api/v1/document-files/uploads", request.httpMethod == "POST" {
            guard let input = try? SummaryJSON.decoder().decode(CreateUploadRequest.self, from: body(of: request)) else { return (400, Data()) }
            let key = UUID().uuidString
            tickets[key] = input
            let ticket = UploadTicket(key: key, uploadUrl: URL(string: "https://todo-storage.invalid/\(key)")!,
                                      headers: ["Content-Type": input.mimeType])
            return (201, (try? SummaryJSON.encoder().encode(ticket)) ?? Data())
        }
        if url.host == "todo-storage.invalid", request.httpMethod == "PUT" {
            let key = url.lastPathComponent
            guard let file = tickets[key], request.value(forHTTPHeaderField: "Authorization") == nil else { return (403, Data()) }
            if file.mimeType.hasPrefix("image/") {
                let bytes = body(of: request)
                if !bytes.isEmpty {
                    imagePreviews[key] = URL(string: "data:\(file.mimeType);base64,\(bytes.base64EncodedString())")
                }
            }
            receivedUploads.insert(key)
            return (200, Data())
        }
        if url.path == "/api/v1/document-files", request.httpMethod == "POST" {
            struct Finalize: Decodable { let uploadKey: String }
            guard let input = try? SummaryJSON.decoder().decode(Finalize.self, from: body(of: request)),
                  receivedUploads.contains(input.uploadKey), let file = tickets[input.uploadKey] else { return (400, Data()) }
            let url = imagePreviews[input.uploadKey] ?? URL(string: "https://todo-storage.invalid/\(input.uploadKey)")!
            let attachment = TodoAttachment(id: input.uploadKey, url: url,
                                           name: file.filename, contentType: file.mimeType, size: file.byteSize)
            return (200, (try? SummaryJSON.encoder().encode(["file": attachment])) ?? Data())
        }
        return nil
    }

    private func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
