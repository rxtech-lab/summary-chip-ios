import Foundation

/// `{ "error": { "code", "message", "requestId" } }` body of any non-2xx response.
public struct APIErrorBody: Codable, Sendable, Hashable {
    public var code: String
    public var message: String
    public var requestId: String?

    public init(code: String, message: String, requestId: String? = nil) {
        self.code = code
        self.message = message
        self.requestId = requestId
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
            case 401: "Your session expired. Please sign in again."
            case 404: "This summary is private, its link expired, or it no longer exists."
            case 413: "That file is too large."
            case 429: "Too many requests. Try again in a moment."
            case 500...: "The server had a problem (\(status)). Please try again."
            default: "The request failed (\(status))."
            }
        case .notSignedIn: "Open Summary Chip and sign in first."
        case .invalidResponse: "The server returned an unexpected response."
        case .decoding(let detail): "Could not read the server response. \(detail)"
        case .fileTooLarge(let max): "PDFs must be smaller than \(ByteCountFormatter.string(fromByteCount: Int64(max), countStyle: .file))."
        case .uploadFailed(let status): "Uploading the file failed (\(status))."
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

    public var isNotFound: Bool { statusCode == 404 }
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
