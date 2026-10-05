import Foundation

private struct FlightEnvelope: Decodable { let flight: Flight }
private struct TripFlightsEnvelope: Decodable { let flights: [TripFlight] }

extension SummaryAPIClient {
    // MARK: Flights

    /// A flight on a local date (`YYYY-MM-DD`). Fails with `404 FLIGHT_NOT_FOUND`
    /// (`isFlightNotFound`) when the flight doesn't operate that day.
    public func lookupFlight(flightNumber: String, date: String) async throws -> Flight {
        struct Body: Encodable { let flightNumber: String; let date: String }
        let envelope: FlightEnvelope = try await send(json("/api/v1/flights/lookup", method: "POST", body: Body(flightNumber: flightNumber, date: date)))
        return envelope.flight
    }

    /// The trip's tracked flight segments, as last stored by the backend.
    public func tripFlights(tripId: String) async throws -> [TripFlight] {
        let envelope: TripFlightsEnvelope = try await send(get("/api/v1/trips/\(tripId.urlPathEscaped)/flights"))
        return envelope.flights
    }

    // MARK: Live Activities

    /// The device's ActivityKit push-to-start token (hex), or `nil` to clear it. The installation
    /// must already be registered with `registerPushDevice`.
    public func registerLiveActivityStartToken(installationId: String, token: String?) async throws {
        struct Body: Encodable {
            let installationId: String
            let pushToStartToken: String?

            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(installationId, forKey: .installationId)
                // `null` clears the token, so send it explicitly.
                try c.encode(pushToStartToken, forKey: .pushToStartToken)
            }

            enum CodingKeys: String, CodingKey { case installationId, pushToStartToken }
        }
        _ = try await sendRaw(json("/api/v1/devices/live-activity", method: "POST", body: Body(installationId: installationId, pushToStartToken: token)))
    }

    /// A running flight activity's update token (hex); `environment` is `sandbox` or `production`.
    public func registerFlightLiveActivity(flightId: String, installationId: String, token: String, environment: String) async throws {
        struct Body: Encodable { let installationId: String; let token: String; let environment: String }
        _ = try await sendRaw(json(
            "/api/v1/flights/\(flightId.urlPathEscaped)/live-activity",
            method: "PUT",
            body: Body(installationId: installationId, token: token, environment: environment)
        ))
    }

    public func unregisterFlightLiveActivity(flightId: String, installationId: String) async throws {
        struct Body: Encodable { let installationId: String }
        _ = try await sendRaw(json("/api/v1/flights/\(flightId.urlPathEscaped)/live-activity", method: "DELETE", body: Body(installationId: installationId)))
    }
}
