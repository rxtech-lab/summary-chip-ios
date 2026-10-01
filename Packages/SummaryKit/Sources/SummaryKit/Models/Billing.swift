import Foundation

/// The server selects a matching storefront. Never contains a secret API key.
public struct BillingConnection: Decodable, Sendable {
    public let serverURL: URL
    public let publishableKey: String
    public let usageItem: String
    public let balanceUnit: String
}
