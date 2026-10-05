import Foundation

// Swift mirror of the flight tracking contract in `docs/flights.md`. The backend polls the flight
// data provider; the apps only read what it stored. Decoding is lenient like the trip document:
// an unknown status decodes as `.unknown` and every field but the airport name may be missing.

public enum FlightStatus: String, TripLenientEnum {
    case scheduled
    case checkIn = "check_in"
    case boarding
    case gateClosed = "gate_closed"
    case departed
    case enRoute = "en_route"
    case approaching
    case delayed
    case landed
    case cancelled
    case diverted
    case unknown
    public static let fallback: Self = .unknown

    public var title: String {
        switch self {
        case .scheduled: String(localized: "Scheduled", bundle: .module)
        case .checkIn: String(localized: "Check-in", bundle: .module)
        case .boarding: String(localized: "Boarding", bundle: .module)
        case .gateClosed: String(localized: "Gate closed", bundle: .module)
        case .departed: String(localized: "Departed", bundle: .module)
        case .enRoute: String(localized: "In the air", bundle: .module)
        case .approaching: String(localized: "Approaching", bundle: .module)
        case .delayed: String(localized: "Delayed", bundle: .module)
        case .landed: String(localized: "Landed", bundle: .module)
        case .cancelled: String(localized: "Cancelled", bundle: .module)
        case .diverted: String(localized: "Diverted", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .scheduled, .unknown: "clock"
        case .checkIn: "person.badge.clock"
        case .boarding, .gateClosed: "door.left.hand.open"
        case .departed: "airplane.departure"
        case .enRoute: "airplane"
        case .approaching, .landed: "airplane.arrival"
        case .delayed: "clock.badge.exclamationmark"
        case .cancelled: "xmark.octagon"
        case .diverted: "arrow.triangle.branch"
        }
    }

    /// Off the ground, on the way.
    public var isAirborne: Bool { [.departed, .enRoute, .approaching].contains(self) }
    /// Nothing more will change.
    public var isFinal: Bool { [.landed, .cancelled, .diverted].contains(self) }
}

public struct FlightAirline: Codable, Sendable, Hashable {
    public var name: String?
    public var iata: String?
    public var icao: String?

    public init(name: String? = nil, iata: String? = nil, icao: String? = nil) {
        self.name = name; self.iata = iata; self.icao = icao
    }
}

/// One end of a flight. Instants are UTC; `*Local` are the airport's wall-clock `YYYY-MM-DDTHH:mm`.
public struct FlightEndpoint: Codable, Sendable, Hashable {
    public var iata: String?
    public var icao: String?
    public var name: String
    public var city: String?
    /// IANA zone of the airport.
    public var timeZone: String?
    public var coordinate: TripCoordinate?
    public var scheduled: Date?
    public var estimated: Date?
    public var actual: Date?
    public var scheduledLocal: String?
    public var estimatedLocal: String?
    public var actualLocal: String?
    public var terminal: String?
    public var gate: String?
    public var checkInDesk: String?
    public var baggageBelt: String?

    public init(
        iata: String? = nil, icao: String? = nil, name: String, city: String? = nil, timeZone: String? = nil, coordinate: TripCoordinate? = nil,
        scheduled: Date? = nil, estimated: Date? = nil, actual: Date? = nil,
        scheduledLocal: String? = nil, estimatedLocal: String? = nil, actualLocal: String? = nil,
        terminal: String? = nil, gate: String? = nil, checkInDesk: String? = nil, baggageBelt: String? = nil
    ) {
        self.iata = iata; self.icao = icao; self.name = name; self.city = city; self.timeZone = timeZone
        self.coordinate = coordinate; self.scheduled = scheduled; self.estimated = estimated; self.actual = actual
        self.scheduledLocal = scheduledLocal; self.estimatedLocal = estimatedLocal; self.actualLocal = actualLocal
        self.terminal = terminal; self.gate = gate; self.checkInDesk = checkInDesk; self.baggageBelt = baggageBelt
    }

    /// Actual, else estimated, else scheduled.
    public var best: Date? { actual ?? estimated ?? scheduled }
    /// The local time matching `best`.
    public var bestLocal: String? { actualLocal ?? estimatedLocal ?? scheduledLocal }
    /// The IATA code, else the ICAO code, else the name.
    public var code: String { iata ?? icao ?? name }
    public var resolvedTimeZone: TimeZone? { timeZone.flatMap(TimeZone.init(identifier:)) }
}

public struct Flight: Codable, Sendable, Hashable, Identifiable {
    /// `<NUMBER>-<YYYY-MM-DD>`, e.g. `CX520-2026-10-12`.
    public var id: String
    public var flightNumber: String
    /// Local departure date, `YYYY-MM-DD`.
    public var date: String
    public var status: FlightStatus
    public var airline: FlightAirline?
    public var aircraft: String?
    public var departure: FlightEndpoint
    public var arrival: FlightEndpoint
    /// Best departure minus scheduled, in whole minutes (negative = early).
    public var delayMinutes: Int?
    public var arrivalDelayMinutes: Int?
    public var updatedAt: Date?

    public init(
        id: String, flightNumber: String, date: String, status: FlightStatus = .unknown, airline: FlightAirline? = nil, aircraft: String? = nil,
        departure: FlightEndpoint, arrival: FlightEndpoint, delayMinutes: Int? = nil, arrivalDelayMinutes: Int? = nil, updatedAt: Date? = nil
    ) {
        self.id = id; self.flightNumber = flightNumber; self.date = date; self.status = status; self.airline = airline
        self.aircraft = aircraft; self.departure = departure; self.arrival = arrival; self.delayMinutes = delayMinutes
        self.arrivalDelayMinutes = arrivalDelayMinutes; self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        flightNumber = try c.decode(String.self, forKey: .flightNumber)
        date = try c.decode(String.self, forKey: .date)
        status = try c.decodeIfPresent(FlightStatus.self, forKey: .status) ?? .unknown
        airline = try c.decodeIfPresent(FlightAirline.self, forKey: .airline)
        aircraft = try c.decodeIfPresent(String.self, forKey: .aircraft)
        departure = try c.decode(FlightEndpoint.self, forKey: .departure)
        arrival = try c.decode(FlightEndpoint.self, forKey: .arrival)
        delayMinutes = try c.decodeIfPresent(Int.self, forKey: .delayMinutes)
        arrivalDelayMinutes = try c.decodeIfPresent(Int.self, forKey: .arrivalDelayMinutes)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// The `id` the backend gives a flight number on a date: upper-cased, no spaces.
    public static func id(flightNumber: String, date: String) -> String {
        "\(flightNumber.filter { !$0.isWhitespace }.uppercased())-\(date)"
    }
}

public enum TripFlightState: String, TripLenientEnum {
    /// Not fetched yet; the backend fetches it within seconds of the save.
    case pending
    case found
    case notFound = "not_found"
    public static let fallback: Self = .pending
}

/// A tracked flight segment of a trip (`GET /api/v1/trips/:id/flights`).
public struct TripFlight: Codable, Sendable, Hashable, Identifiable {
    public var transportId: String
    public var optionId: String
    public var segmentIndex: Int
    public var flightId: String
    public var flightNumber: String
    public var date: String
    public var state: TripFlightState
    public var flight: Flight?

    public init(
        transportId: String, optionId: String, segmentIndex: Int, flightId: String, flightNumber: String, date: String,
        state: TripFlightState = .pending, flight: Flight? = nil
    ) {
        self.transportId = transportId; self.optionId = optionId; self.segmentIndex = segmentIndex; self.flightId = flightId
        self.flightNumber = flightNumber; self.date = date; self.state = state; self.flight = flight
    }

    public var id: String { "\(transportId)/\(optionId)/\(segmentIndex)" }
}

public extension TripTransportOption {
    /// The local `YYYY-MM-DD` a flight segment is tracked on: the segment's departure, else the
    /// option's, else `fallback` (the transport's date).
    func flightDate(segmentIndex: Int, fallback: String) -> String {
        let departure = segments.indices.contains(segmentIndex) ? segments[segmentIndex].departure : nil
        return String((departure ?? self.departure ?? fallback).prefix(10))
    }
}

/// Short labels shared by the app's flight cards and the Live Activity.
public enum FlightText {
    /// "+25 min" late, "10 min early", nil when on time.
    public static func delay(minutes: Int?) -> String? {
        guard let minutes, minutes != 0 else { return nil }
        return minutes > 0
            ? String(localized: "+\(minutes) min", bundle: .module)
            : String(localized: "\(-minutes) min early", bundle: .module)
    }

    public static func terminal(_ terminal: String) -> String { String(localized: "Terminal \(terminal)", bundle: .module) }
    /// "T1", for tight spaces.
    public static func shortTerminal(_ terminal: String) -> String { String(localized: "T\(terminal)", bundle: .module) }
    public static func gate(_ gate: String) -> String { String(localized: "Gate \(gate)", bundle: .module) }
    public static func baggageBelt(_ belt: String) -> String { String(localized: "Belt \(belt)", bundle: .module) }

    /// "T1 · Gate B12", or nil when neither is known.
    public static func terminalAndGate(terminal: String?, gate: String?) -> String? {
        let parts = [terminal.map(shortTerminal), gate.map(Self.gate)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
