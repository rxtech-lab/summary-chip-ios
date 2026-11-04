import Foundation

public struct LiveChatSession: Decodable, Sendable {
    public let model: String
    public let url: URL
    public let protocols: [String]?
    public let config: JSONValue
}

extension SummaryAPIClient {
    public func createLiveChatSession(context: ChatRequestBody) async throws -> LiveChatSession {
        var request = try json("api/v1/chat/live", method: "POST", body: context)
        await applyBillingProof(to: &request)
        return try await send(request)
    }
    public func executeLiveChatTool(context: ChatRequestBody, name: String, callID: String, input: JSONValue) async throws -> JSONValue {
        struct Body: Encodable { let context: ChatRequestBody; let name: String; let callId: String; let input: JSONValue }
        struct Result: Decodable { let output: JSONValue }
        let request = try json("api/v1/chat/live/tool", method: "POST", body: Body(context: context, name: name, callId: callID, input: input))
        let result: Result = try await send(request)
        return result.output
    }

}
