import Foundation

/// Stable, private storage reference saved with the turn. Signed URLs are short-lived.
public struct ChatAttachmentReference: Codable, Sendable, Hashable, Identifiable {
    public let uploadKey: String
    public let filename: String
    public let mimeType: String
    public var id: String { uploadKey }

    public init(uploadKey: String, filename: String, mimeType: String) {
        self.uploadKey = uploadKey
        self.filename = filename
        self.mimeType = mimeType
    }
}

extension ChatStreamClient {
    public func uploadAttachment(_ file: ChatFileAttachment, onProgress: @escaping MediaTransferProgress.Handler) async throws -> ChatAttachmentReference {
        let metadata = CreateUploadRequest(filename: file.filename, mimeType: file.mimeType, byteSize: file.data.count)
        let ticket: UploadTicket = try await api.send(api.json("/api/v1/chat/uploads", method: "POST", body: metadata))
        try Task.checkCancellation()
        var put = URLRequest(url: ticket.uploadUrl)
        put.httpMethod = "PUT"
        put.timeoutInterval = SummaryAPIClient.createTimeout
        for (name, value) in ticket.headers { put.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await api.session.upload(for: put, from: file.data, delegate: MediaTransferDelegate(onProgress))
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SummaryAPIError.uploadFailed(status: http.statusCode) }
        return ChatAttachmentReference(uploadKey: ticket.key, filename: file.filename, mimeType: file.mimeType)
    }
}
