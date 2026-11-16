import Foundation

/// Independent of authentication and storage vendors: the host supplies its signed PUT request.
public enum DirectImageUpload {
    public static func upload(_ data: Data, request: URLRequest,
                              progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let delegate = UploadProgress(progress: progress)
        let (_, response) = try await URLSession.shared.upload(for: request, from: data, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        progress(Int64(data.count), Int64(data.count))
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }
}
