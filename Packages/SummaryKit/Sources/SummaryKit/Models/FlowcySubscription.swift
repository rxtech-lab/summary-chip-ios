import Foundation

public struct FlowcySubscription: Decodable, Sendable {
    public enum Provider: String, Decodable, Sendable {
        case apple
        case flowcy
    }

    public static let appleProductID = "com.rxlab.chippy.flowcy.plus.monthly"
    public static let accessRequired = Notification.Name("app.chippy.flowcySubscriptionRequired")

    public let active: Bool
    public let provider: Provider?
    public let productId: String?
}
