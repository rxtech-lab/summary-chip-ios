import Foundation
import Testing
@testable import SummaryKit

private let flightJSON = """
{
  "id": "CX520-2026-10-12",
  "flightNumber": "CX 520",
  "date": "2026-10-12",
  "status": "en_route",
  "airline": { "name": "Cathay Pacific", "iata": "CX", "icao": "CPA" },
  "aircraft": "Airbus A350-900",
  "departure": {
    "iata": "HKG", "icao": "VHHH", "name": "Hong Kong", "city": "Hong Kong",
    "timeZone": "Asia/Hong_Kong", "coordinate": { "lat": 22.31, "lng": 113.92 },
    "scheduled": "2026-10-12T01:05:00.000Z", "estimated": "2026-10-12T01:30:00.000Z", "actual": null,
    "scheduledLocal": "2026-10-12T09:05", "estimatedLocal": "2026-10-12T09:30", "actualLocal": null,
    "terminal": "1", "gate": "B12", "checkInDesk": null, "baggageBelt": null
  },
  "arrival": {
    "iata": null, "icao": null, "name": "Tokyo Haneda", "city": null,
    "timeZone": null, "coordinate": null,
    "scheduled": "2026-10-12T05:20:00.000Z", "estimated": null, "actual": null,
    "scheduledLocal": "2026-10-12T14:20", "estimatedLocal": null, "actualLocal": null,
    "terminal": null, "gate": null, "checkInDesk": null, "baggageBelt": "7"
  },
  "delayMinutes": 25,
  "arrivalDelayMinutes": null,
  "updatedAt": "2026-10-12T00:41:12.000Z"
}
"""

@Suite struct FlightDecodingTests {
    @Test func decodesFlight() throws {
        let flight = try SummaryJSON.decoder().decode(Flight.self, from: Data(flightJSON.utf8))
        #expect(flight.id == "CX520-2026-10-12")
        #expect(flight.status == .enRoute)
        #expect(flight.status.isAirborne)
        #expect(flight.airline?.name == "Cathay Pacific")
        #expect(flight.departure.code == "HKG")
        #expect(flight.departure.coordinate?.lat == 22.31)
        #expect(flight.departure.best == SummaryJSON.parseISO8601("2026-10-12T01:30:00.000Z"))
        #expect(flight.departure.bestLocal == "2026-10-12T09:30")
        #expect(flight.departure.resolvedTimeZone?.identifier == "Asia/Hong_Kong")
        #expect(flight.arrival.code == "Tokyo Haneda") // no codes → name
        #expect(flight.arrival.baggageBelt == "7")
        #expect(flight.delayMinutes == 25)
        #expect(flight.arrivalDelayMinutes == nil)
        #expect(flight.updatedAt != nil)
    }

    @Test func unknownStatusFallsBack() throws {
        let json = flightJSON.replacingOccurrences(of: "\"en_route\"", with: "\"taxiing\"")
        let flight = try SummaryJSON.decoder().decode(Flight.self, from: Data(json.utf8))
        #expect(flight.status == .unknown)
        #expect(FlightStatus(rawValue: "check_in") == .checkIn)
        #expect(FlightStatus(rawValue: "gate_closed") == .gateClosed)
    }

    @Test func decodesTripFlights() throws {
        struct Envelope: Decodable { let flights: [TripFlight] }
        let json = """
        { "flights": [
          { "transportId": "flight-out", "optionId": "cx520", "segmentIndex": 0,
            "flightId": "CX520-2026-10-12", "flightNumber": "CX 520", "date": "2026-10-12",
            "state": "found", "flight": \(flightJSON) },
          { "transportId": "flight-back", "optionId": "cx521", "segmentIndex": 1,
            "flightId": "CX521-2026-10-20", "flightNumber": "CX 521", "date": "2026-10-20",
            "state": "pending", "flight": null },
          { "transportId": "x", "optionId": "y", "segmentIndex": 0,
            "flightId": "ZZ1-2026-10-21", "flightNumber": "ZZ 1", "date": "2026-10-21",
            "state": "not_found" },
          { "transportId": "x", "optionId": "y", "segmentIndex": 2,
            "flightId": "ZZ2-2026-10-21", "flightNumber": "ZZ 2", "date": "2026-10-21",
            "state": "mystery", "flight": null }
        ] }
        """
        let flights = try SummaryJSON.decoder().decode(Envelope.self, from: Data(json.utf8)).flights
        #expect(flights.count == 4)
        #expect(flights[0].state == .found)
        #expect(flights[0].flight?.flightNumber == "CX 520")
        #expect(flights[0].id == "flight-out/cx520/0")
        #expect(flights[1].state == .pending && flights[1].flight == nil)
        #expect(flights[2].state == .notFound && flights[2].flight == nil)
        #expect(flights[3].state == .pending) // unknown → fallback
    }

    @Test func flightIDMatchesBackend() {
        #expect(Flight.id(flightNumber: "cx 520", date: "2026-10-12") == "CX520-2026-10-12")
    }

    @Test func flightDateFallsBack() {
        let option = TripTransportOption(id: "o", label: "O", departure: "2026-10-11T23:00", segments: [
            TripSegment(mode: .flight, fromName: "A", toName: "B", departure: "2026-10-12T09:05"),
            TripSegment(mode: .flight, fromName: "B", toName: "C"),
        ])
        #expect(option.flightDate(segmentIndex: 0, fallback: "2026-10-01") == "2026-10-12")
        #expect(option.flightDate(segmentIndex: 1, fallback: "2026-10-01") == "2026-10-11")
        let bare = TripTransportOption(id: "o", label: "O")
        #expect(bare.flightDate(segmentIndex: 0, fallback: "2026-10-01") == "2026-10-01")
    }

    @Test func notFoundErrorIsRecognised() {
        let error = SummaryAPIError.server(status: 404, body: APIErrorBody(code: "FLIGHT_NOT_FOUND", message: "No flight"))
        #expect(error.isFlightNotFound)
        #expect(!SummaryAPIError.http(status: 404).isFlightNotFound)
    }

}

@Suite(.serialized) struct FlightRequestTests {
    @Test func lookupNotFoundIsRecognised() async throws {
        FlightRequestProtocol.requests.clear()
        do {
            _ = try await client().lookupFlight(flightNumber: "ZZ 999", date: "2026-10-12")
            Issue.record("Expected FLIGHT_NOT_FOUND")
        } catch let error as SummaryAPIError {
            #expect(error.isFlightNotFound)
        }
        let request = try #require(FlightRequestProtocol.requests.values.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/flights/lookup")
        #expect(request.bodyString == #"{"date":"2026-10-12","flightNumber":"ZZ 999"}"#)
    }

    @Test func liveActivityTokenRequests() async throws {
        FlightRequestProtocol.requests.clear()
        let api = client()
        try await api.registerLiveActivityStartToken(installationId: "i", token: nil)
        try await api.registerFlightLiveActivity(flightId: "CX520-2026-10-12", installationId: "i", token: "ab", environment: "sandbox")
        try await api.unregisterFlightLiveActivity(flightId: "CX520-2026-10-12", installationId: "i")
        let requests = FlightRequestProtocol.requests.values
        #expect(requests.map(\.httpMethod) == ["POST", "PUT", "DELETE"])
        #expect(requests[0].url?.path == "/api/v1/devices/live-activity")
        // `null` clears the token, so it must be sent rather than omitted.
        #expect(requests[0].bodyString == #"{"installationId":"i","pushToStartToken":null}"#)
        #expect(requests[1].url?.path == "/api/v1/flights/CX520-2026-10-12/live-activity")
        #expect(requests[1].bodyString == #"{"environment":"sandbox","installationId":"i","token":"ab"}"#)
        #expect(requests[2].bodyString == #"{"installationId":"i"}"#)
    }

    private func client() -> SummaryAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightRequestProtocol.self]
        return SummaryAPIClient(baseURL: URL(string: "https://flights.test")!, tokenProvider: FlightTestToken(),
            session: URLSession(configuration: configuration), billingProofProvider: { nil })
    }
}

private struct FlightTestToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

private struct RecordedRequest: Sendable {
    var httpMethod: String?
    var url: URL?
    var bodyString: String?
}

private final class FlightRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedRequest] = []
    var values: [RecordedRequest] { lock.withLock { storage } }
    func append(_ request: RecordedRequest) { lock.withLock { storage.append(request) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

private final class FlightRequestProtocol: URLProtocol, @unchecked Sendable {
    static let requests = FlightRequestRecorder()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "flights.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(RecordedRequest(httpMethod: request.httpMethod, url: request.url, bodyString: body.map { String(decoding: $0, as: UTF8.self) }))
        let notFound = request.url?.path == "/api/v1/flights/lookup"
        let status = notFound ? 404 : 204
        let json = notFound ? #"{"error":{"code":"FLIGHT_NOT_FOUND","message":"No such flight."}}"# : ""
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands protocols the body as a stream.
    private var body: Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
