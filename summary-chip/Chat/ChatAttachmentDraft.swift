import Foundation
import Observation
import SummaryKit

struct ChatAttachmentProgress: Equatable {
    let filename: String
    var bytesSent: Int64 = 0
    var totalBytes: Int64 = 0
}

@Observable
final class ChatAttachmentDraft {
    private let client: ChatStreamClient
    private(set) var attachments: [ChatAttachmentReference] = []
    private(set) var uploadProgress: ChatAttachmentProgress?
    var attachmentError: String?
    private var uploadTask: Task<Void, Never>?
    private var currentFileID: UUID?

    init(client: ChatStreamClient) {
        self.client = client
    }

    func addFiles(_ urls: [URL]) {
        guard let first = urls.first, uploadProgress == nil else { return }
        guard urls.count + attachments.count <= ChatFileAttachment.maxCount else {
            attachmentError = String(localized: "Choose up to \(ChatFileAttachment.maxCount) files per message.")
            return
        }
        uploadProgress = ChatAttachmentProgress(filename: first.lastPathComponent)
        attachmentError = nil
        uploadTask = Task {
            var errors: [String] = []
            for url in urls {
                guard !Task.isCancelled else { return }
                do {
                    try await upload(url)
                } catch {
                    guard !Task.isCancelled else { return }
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { return }
            currentFileID = nil
            uploadProgress = nil
            uploadTask = nil
            if !errors.isEmpty { attachmentError = errors.joined(separator: "\n") }
        }
    }

    private func upload(_ url: URL) async throws {
        let fileID = UUID()
        currentFileID = fileID
        uploadProgress = ChatAttachmentProgress(filename: url.lastPathComponent)
        let file = try await Task.detached(priority: .userInitiated) {
            try ChatFileAttachment.read(url)
        }.value
        try Task.checkCancellation()
        uploadProgress = ChatAttachmentProgress(filename: file.filename, totalBytes: Int64(file.data.count))
        let uploaded = try await client.uploadAttachment(file) { [weak self] progress in
            guard let self, currentFileID == fileID else { return }
            uploadProgress?.bytesSent = progress.completedBytes
        }
        try Task.checkCancellation()
        attachments.append(uploaded)
    }

    func removeAttachment(_ attachment: ChatAttachmentReference) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func cancelAttachmentUpload() {
        uploadTask?.cancel()
        uploadTask = nil
        currentFileID = nil
        uploadProgress = nil
    }

    func reset() {
        cancelAttachmentUpload()
        attachments = []
        attachmentError = nil
    }
}
