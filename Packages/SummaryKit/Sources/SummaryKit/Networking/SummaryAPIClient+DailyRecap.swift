import Foundation

public struct DailyRecapSettings: Codable, Sendable {
    public struct Run: Codable, Sendable {
        public let date: String
        public let status: String
        public let episodeKey: String?
        public let error: String?
    }
    public let enabled: Bool
    public let timeZone: String
    public let language: String
    public let hour: Int
    public let nextAt: Date?
    public let lastRun: Run?
}

extension SummaryAPIClient {
    public func dailyRecapSettings() async throws -> DailyRecapSettings {
        try await send(get("/api/v1/daily-recap"))
    }

    public func saveDailyRecapSettings(enabled: Bool, timeZone: String, language: String, hour: Int) async throws -> DailyRecapSettings {
        struct Input: Encodable {
            let enabled: Bool
            let timeZone: String
            let language: String
            let hour: Int
        }
        return try await send(json("/api/v1/daily-recap", method: "PUT", body: Input(enabled: enabled, timeZone: timeZone, language: language, hour: hour)))
    }
}
