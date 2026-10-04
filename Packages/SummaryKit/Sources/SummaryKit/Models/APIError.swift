import Foundation

/// `{ "error": { "code", "message", "requestId", "details"? } }` body of any non-2xx response.
public struct APIErrorBody: Codable, Sendable, Hashable {
    public var code: String
    public var message: String
    public var requestId: String?
    public var details: JSONValue?

    public init(code: String, message: String, requestId: String? = nil, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.requestId = requestId
        self.details = details
    }
}

struct APIErrorEnvelope: Codable, Sendable {
    var error: APIErrorBody
}

public enum SummaryAPIError: Error, LocalizedError, Sendable, Equatable {
    /// Server returned a contract error envelope.
    case server(status: Int, body: APIErrorBody)
    /// Non-2xx without a decodable envelope.
    case http(status: Int)
    case notSignedIn
    case invalidResponse
    case decoding(String)
    case fileTooLarge(maxBytes: Int)
    case uploadFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .server(_, let body): body.message
        case .http(let status):
            switch status {
            case 401: String(localized: "Your session expired. Please sign in again.", bundle: .module)
            case 404: String(localized: "This summary is private, its link expired, or it no longer exists.", bundle: .module)
            case 413: String(localized: "That file is too large.", bundle: .module)
            case 429: String(localized: "Too many requests. Try again in a moment.", bundle: .module)
            case 500...: String(localized: "The server had a problem (\(status)). Please try again.", bundle: .module)
            default: String(localized: "The request failed (\(status)).", bundle: .module)
            }
        case .notSignedIn: String(localized: "Open Chippy and sign in first.", bundle: .module)
        case .invalidResponse: String(localized: "The server returned an unexpected response.", bundle: .module)
        case .decoding(let detail): String(localized: "Could not read the server response. \(detail)", bundle: .module)
        case .fileTooLarge(let max): String(localized: "PDFs must be smaller than \(ByteCountFormatter.string(fromByteCount: Int64(max), countStyle: .file)).", bundle: .module)
        case .uploadFailed(let status): String(localized: "Uploading the file failed (\(status)).", bundle: .module)
        }
    }

    public var statusCode: Int? {
        switch self {
        case .server(let status, _), .http(let status), .uploadFailed(let status): status
        default: nil
        }
    }

    public var code: String? {
        if case .server(_, let body) = self { return body.code }
        return nil
    }

    /// The page the server could not read and asks the device to read (`SOURCE_NEEDS_DEVICE`).
    public var deviceReadURL: URL? {
        guard case .server(_, let body) = self, body.code == "SOURCE_NEEDS_DEVICE",
              let value = body.details?["url"]?.stringValue,
              let url = URL(string: value), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    public var isNotFound: Bool { statusCode == 404 }
    /// Out of free summaries or points (`SUMMARY_ALLOWANCE_EXHAUSTED`), or out of points to chat
    /// (`CHAT_POINTS_EXHAUSTED`) or translate (`TRANSLATION_POINTS_EXHAUSTED`).
    public var needsTopUp: Bool {
        statusCode == 402
            && (code == "SUMMARY_ALLOWANCE_EXHAUSTED" || code == "CHAT_POINTS_EXHAUSTED" || code == "TRANSLATION_POINTS_EXHAUSTED")
    }
    public var isUnauthorized: Bool { statusCode == 401 || self == .notSignedIn }
}

/// JSON coders configured for the contract (camelCase, ISO-8601 with or without fractions).
public enum SummaryJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                // Tolerate epoch milliseconds.
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            }
            let value = try container.decode(String.self)
            if let date = parseISO8601(value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func parseISO8601(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(value, strategy: Date.ISO8601FormatStyle())
    }
}

/// Neither the server (fetch and headless browser) nor the device's web view could read a link.
/// Safari can usually open it; sharing the open page to Chippy sends its text directly.
public struct UnreadablePageError: Error, LocalizedError, Sendable, Hashable, Identifiable {
    public let url: URL
    /// Why the on-device read failed.
    public let reason: String

    public var id: URL { url }

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }

    public var errorDescription: String? {
        String(localized: "Chippy couldn't read this page. Open it in Safari, then share it to Chippy from the Share menu.", bundle: .module)
    }
}
