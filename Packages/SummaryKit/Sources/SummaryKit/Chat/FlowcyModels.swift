import Foundation

public struct FlowcyModel: Decodable, Hashable, Identifiable, Sendable {
    public let modelId: String
    public let alias: String
    public var id: String { modelId }
}

public struct FlowcyModelCatalog: Decodable, Sendable {
    public let models: [FlowcyModel]
    public let selectedModelId: String?
}

public struct FlowcyModelUsage: Decodable, Sendable {
    public enum Unit: String, Decodable, Sendable { case microUSD = "micro_usd" }
    public enum Window: String, CaseIterable, Sendable {
        case fiveHours = "agent_cost_5h"
        case sevenDays = "agent_cost_7d"
        case thirtyDays = "agent_cost_30d"
    }
    public struct Meter: Decodable, Sendable {
        public let key: String
        private let used: Double
        private let limit: Double?

        public var fractionUsed: Double? {
            guard let limit, limit > 0 else { return nil }
            return used / limit
        }
    }

    public let unit: Unit
    public let meters: [Meter]
}

extension SummaryAPIClient {
    public func flowcyModels() async throws -> FlowcyModelCatalog {
        try await send(get("/api/v1/ai/models"))
    }

    public func flowcyModelUsage() async throws -> FlowcyModelUsage {
        try await send(get("/api/v1/ai/usage"))
    }

    public func selectFlowcyModel(_ id: String?) async throws {
        var request = get("/api/v1/ai/models")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["modelId": id])
        _ = try await sendRaw(request)
    }

    public func chatAttachment(_ reference: ChatAttachmentReference) async throws -> Data {
        try await sendRaw(get("/api/v1/chat/uploads", query: [URLQueryItem(name: "key", value: reference.uploadKey)]))
    }
}
