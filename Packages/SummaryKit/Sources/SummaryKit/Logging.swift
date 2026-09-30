import Foundation
import os

/// Unified-logging categories for SummaryKit. Filter in Console.app with
/// `subsystem:com.rxlab.summary-chip`.
enum SummaryLog {
    static let subsystem = "com.rxlab.summary-chip"
    static let api = Logger(subsystem: subsystem, category: "API")
    static let chat = Logger(subsystem: subsystem, category: "Chat")
    static let assets = Logger(subsystem: subsystem, category: "AssetLoader")
}

extension URLRequest {
    /// `GET /api/v1/summaries?limit=20` — never includes headers (bearer token).
    var logDescription: String {
        "\(httpMethod ?? "GET") \(url?.absoluteString ?? "<nil>")"
    }
}

extension Error {
    /// Compact, greppable description; URL errors include their code and failing host so DNS /
    /// ATS / offline failures are obvious in Console.
    var logDescription: String {
        if let urlError = self as? URLError {
            let host = urlError.failingURL?.host() ?? "?"
            return "URLError \(urlError.code.rawValue) (\(urlError.code.name)) host=\(host): \(urlError.localizedDescription)"
        }
        return String(describing: self)
    }
}

extension URLError.Code {
    var name: String {
        switch self {
        case .cannotFindHost: "cannotFindHost"
        case .cannotConnectToHost: "cannotConnectToHost"
        case .dnsLookupFailed: "dnsLookupFailed"
        case .notConnectedToInternet: "notConnectedToInternet"
        case .networkConnectionLost: "networkConnectionLost"
        case .timedOut: "timedOut"
        case .cancelled: "cancelled"
        case .secureConnectionFailed: "secureConnectionFailed"
        case .appTransportSecurityRequiresSecureConnection: "atsRequiresSecureConnection"
        case .serverCertificateUntrusted: "serverCertificateUntrusted"
        case .badServerResponse: "badServerResponse"
        default: "other"
        }
    }
}
