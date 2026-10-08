import Foundation

private struct TripTourEnvelope: Decodable { let tour: TripTour }
private struct TripTourRequest: Encodable { let regenerate: Bool }

extension SummaryAPIClient {
    /// Writing a long trip's tour runs several model calls.
    public static let tourTimeout: TimeInterval = 180

    static func isTripTourPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("/api/v1/trips/") && path.hasSuffix("/tour")
    }

    // MARK: Tours

    /// The trip's tour as the user follows and reads it (`POST /api/v1/trips/:id/tour`): the stored
    /// one when current, else written now, which costs points (`402 TOUR_POINTS_EXHAUSTED`).
    public func tripTour(tripId: String, regenerate: Bool = false) async throws -> TripTour {
        var request = try json("/api/v1/trips/\(tripId.urlPathEscaped)/tour", method: "POST", body: TripTourRequest(regenerate: regenerate))
        request.timeoutInterval = Self.tourTimeout
        let envelope: TripTourEnvelope = try await send(request)
        return envelope.tour
    }

    /// A scene's narration as MP3 (`scene.audioPath`), read aloud by the server the first time.
    public func tripTourAudio(_ scene: TripTourScene) async throws -> Data {
        var request = request(scene.audioPath)
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return try await sendRaw(request)
    }
}
