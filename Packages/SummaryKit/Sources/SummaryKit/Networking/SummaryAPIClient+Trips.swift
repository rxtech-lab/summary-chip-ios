import Foundation

private struct TripEnvelope: Decodable { let trip: Trip }
private struct TripListEnvelope: Decodable { let trips: [TripListItem] }

/// `202 {status:"queued"}` from `POST /api/v1/trips/:id/ingest`.
public struct TripIngestReceipt: Decodable, Sendable, Hashable {
    public var status: String

    public init(status: String = "queued") { self.status = status }
}

extension SummaryAPIClient {
    /// The agent reads the source in the background and updates the trip; it can run past the extension's lifetime.
    public static let ingestTimeout: TimeInterval = 120

    static func isTripIngestPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("/api/v1/trips/") && path.hasSuffix("/ingest")
    }

    // MARK: Trips

    /// The account's trips (`GET /api/v1/trips`).
    public func listTrips() async throws -> [TripListItem] {
        let envelope: TripListEnvelope = try await send(get("/api/v1/trips"))
        return envelope.trips
    }

    /// A trip's document, in the language the user reads it in (see `Trip.isTranslated`); `id` is its summary id.
    public func trip(id: String) async throws -> Trip {
        var request = get("/api/v1/trips/\(id.urlPathEscaped)")
        // Texts not translated yet into the reading language are translated before the response.
        request.timeoutInterval = Self.createTimeout
        let envelope: TripEnvelope = try await send(request)
        return envelope.trip
    }

    /// The languages the trip is already translated into; nothing is translated by asking. The
    /// reading language itself is the trip's library item's `displayLanguage` (`updateSummary`).
    public func tripTranslations(id: String) async throws -> SummaryTranslations {
        try await send(get("/api/v1/trips/\(id.urlPathEscaped)/translations"))
    }

    public func createTrip(document: TripDocument, visibility: SummaryVisibility = .private) async throws -> Trip {
        struct Body: Encodable { let document: TripDocument; let visibility: SummaryVisibility }
        var request = try json("/api/v1/trips", method: "POST", body: Body(document: document, visibility: visibility))
        request.timeoutInterval = Self.createTimeout
        let envelope: TripEnvelope = try await send(request)
        return envelope.trip
    }

    /// Replaces the document. Fails with `409 TRIP_REVISION_CONFLICT` (`isTripRevisionConflict`)
    /// when someone else (usually the agent) saved since `revision`.
    public func saveTrip(id: String, document: TripDocument, revision: Int) async throws -> Trip {
        struct Body: Encodable { let document: TripDocument; let revision: Int }
        let envelope: TripEnvelope = try await send(json("/api/v1/trips/\(id.urlPathEscaped)", method: "PUT", body: Body(document: document, revision: revision)))
        return envelope.trip
    }

    /// Applies entity-level edits in order, atomically; with `revision`, only if nothing changed since.
    public func applyTripOperations(id: String, operations: [TripOperation], revision: Int? = nil) async throws -> Trip {
        struct Body: Encodable { let operations: [TripOperation]; let revision: Int? }
        let envelope: TripEnvelope = try await send(json("/api/v1/trips/\(id.urlPathEscaped)/operations", method: "POST", body: Body(operations: operations, revision: revision)))
        return envelope.trip
    }

    /// Picks the option of a plan the user follows (`nil` goes back to the plan's default). Saved for
    /// the user only: the document and its revision don't change. Returns all their picks.
    @discardableResult
    public func selectTripPlanOption(tripId: String, planId: String, optionId: String?) async throws -> [String: String] {
        struct Body: Encodable {
            let planId: String
            let optionId: String?
            // `optionId: null` is meaningful, so it is always sent.
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(planId, forKey: .planId)
                try c.encode(optionId, forKey: .optionId)
            }
            enum CodingKeys: String, CodingKey { case planId, optionId }
        }
        struct Envelope: Decodable { let planSelections: [String: String] }
        let envelope: Envelope = try await send(json(
            "/api/v1/trips/\(tripId.urlPathEscaped)/plan-selections",
            method: "PUT",
            body: Body(planId: planId, optionId: optionId)
        ))
        return envelope.planSelections
    }

    /// Printing waits for the trip's photos, so it takes longer than other calls.
    public static let tripPDFTimeout: TimeInterval = 120

    /// The trip as an A4 PDF report (`GET /api/v1/trips/:id/pdf`), in the app's language. Fails with
    /// `503 PDF_UNAVAILABLE` when the server can't print and `502 PDF_RENDER_FAILED` when printing failed.
    public func tripPDF(id: String) async throws -> Data {
        var request = request("/api/v1/trips/\(id.urlPathEscaped)/pdf")
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.tripPDFTimeout
        return try await sendRaw(request)
    }

    public func deleteTrip(id: String) async throws {
        var request = request("/api/v1/trips/\(id.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    /// Hands a shared page, PDF or text to the trip agent, which updates the trip in the background
    /// and sends a push when done. Out of points fails with `402 TRIP_POINTS_EXHAUSTED` (`needsTopUp`).
    @discardableResult
    public func ingestIntoTrip(
        id: String,
        input: SummaryInput,
        instructions: String? = nil,
        onUploaded: (@Sendable () -> Void)? = nil
    ) async throws -> TripIngestReceipt {
        struct Body: Encodable { let source: SummarySource; let instructions: String? }
        let source = try await source(for: input, onUploaded: onUploaded)
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = try json(
            "/api/v1/trips/\(id.urlPathEscaped)/ingest",
            method: "POST",
            body: Body(source: source, instructions: trimmed?.isEmpty == false ? trimmed : nil)
        )
        request.timeoutInterval = Self.ingestTimeout
        let data = try await sendRaw(request)
        return (try? SummaryJSON.decoder().decode(TripIngestReceipt.self, from: data)) ?? TripIngestReceipt()
    }
}
