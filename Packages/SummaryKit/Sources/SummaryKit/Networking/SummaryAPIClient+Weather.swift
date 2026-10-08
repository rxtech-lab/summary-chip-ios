import Foundation

extension SummaryAPIClient {
    // MARK: Weather

    /// The trip's forecasts per day (and where the reader is now, during the trip), as last stored
    /// by the backend. Spec: `docs/weather.md`.
    public func tripWeather(tripId: String) async throws -> TripWeather {
        try await send(get("/api/v1/trips/\(tripId.urlPathEscaped)/weather"))
    }
}
