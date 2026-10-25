import Foundation

public struct MediaTransferProgress: Sendable, Equatable {
    public typealias Handler = @MainActor @Sendable (MediaTransferProgress) -> Void
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    public var fraction: Double? {
        totalBytes.map { min(1, Double(completedBytes) / Double($0)) }
    }

    public var detail: String {
        let completed = (Double(completedBytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        guard let totalBytes else { return "\(completed) MB" }
        let total = (Double(totalBytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        return "\(completed) / \(total) MB"
    }
}

/// Task-scoped delegate; the existing session retains its configuration and authentication behavior.
final class MediaTransferDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onProgress: MediaTransferProgress.Handler
    init(_ onProgress: @escaping MediaTransferProgress.Handler) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent, totalBytesExpectedToSend)
    }

    private func report(_ completed: Int64, _ total: Int64) {
        let progress = MediaTransferProgress(completedBytes: completed, totalBytes: total)
        Task { @MainActor [onProgress] in onProgress(progress) }
    }
}
