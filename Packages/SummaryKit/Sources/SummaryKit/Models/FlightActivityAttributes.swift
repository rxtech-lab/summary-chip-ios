#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// A flight's Live Activity, shared by the app (which starts it locally or registers its tokens) and
/// the widget extension (which draws it). The backend starts and updates it with pushes, so the
/// shape must match `docs/flights.md` exactly, including the name `FlightActivityAttributes`.
///
/// Dates are Unix seconds (`Double`), not `Date`: ActivityKit decodes pushed JSON with the default
/// decoder, which reads `Date` as seconds since 2001.
public struct FlightActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// `Flight.status`.
        public var status: String
        public var departureScheduled: Double
        /// Actual, else estimated, else scheduled.
        public var departureBest: Double
        public var arrivalScheduled: Double
        public var arrivalBest: Double
        public var departureTerminal: String?
        public var departureGate: String?
        public var arrivalTerminal: String?
        public var arrivalGate: String?
        public var baggageBelt: String?
        public var delayMinutes: Int
        public var updatedAt: Double

        public init(
            status: String, departureScheduled: Double, departureBest: Double, arrivalScheduled: Double, arrivalBest: Double,
            departureTerminal: String? = nil, departureGate: String? = nil, arrivalTerminal: String? = nil, arrivalGate: String? = nil,
            baggageBelt: String? = nil, delayMinutes: Int = 0, updatedAt: Double
        ) {
            self.status = status; self.departureScheduled = departureScheduled; self.departureBest = departureBest
            self.arrivalScheduled = arrivalScheduled; self.arrivalBest = arrivalBest; self.departureTerminal = departureTerminal
            self.departureGate = departureGate; self.arrivalTerminal = arrivalTerminal; self.arrivalGate = arrivalGate
            self.baggageBelt = baggageBelt; self.delayMinutes = delayMinutes; self.updatedAt = updatedAt
        }

        /// The state for a stored flight; nil without scheduled departure and arrival times.
        public init?(flight: Flight) {
            guard let departure = flight.departure.scheduled, let arrival = flight.arrival.scheduled else { return nil }
            self.init(
                status: flight.status.rawValue,
                departureScheduled: departure.timeIntervalSince1970,
                departureBest: (flight.departure.best ?? departure).timeIntervalSince1970,
                arrivalScheduled: arrival.timeIntervalSince1970,
                arrivalBest: (flight.arrival.best ?? arrival).timeIntervalSince1970,
                departureTerminal: flight.departure.terminal,
                departureGate: flight.departure.gate,
                arrivalTerminal: flight.arrival.terminal,
                arrivalGate: flight.arrival.gate,
                baggageBelt: flight.arrival.baggageBelt,
                delayMinutes: flight.delayMinutes ?? 0,
                updatedAt: (flight.updatedAt ?? Date()).timeIntervalSince1970
            )
        }

        public var flightStatus: FlightStatus { FlightStatus(rawValue: status) ?? .unknown }
        public var departureScheduledDate: Date { Date(timeIntervalSince1970: departureScheduled) }
        public var departureBestDate: Date { Date(timeIntervalSince1970: departureBest) }
        public var arrivalScheduledDate: Date { Date(timeIntervalSince1970: arrivalScheduled) }
        public var arrivalBestDate: Date { Date(timeIntervalSince1970: arrivalBest) }
        public var updatedAtDate: Date { Date(timeIntervalSince1970: updatedAt) }
    }

    public var flightId: String
    public var tripId: String
    public var flightNumber: String
    public var airlineName: String?
    public var fromIATA: String
    public var toIATA: String
    public var fromCity: String?
    public var toCity: String?

    public init(
        flightId: String, tripId: String, flightNumber: String, airlineName: String? = nil, fromIATA: String, toIATA: String,
        fromCity: String? = nil, toCity: String? = nil
    ) {
        self.flightId = flightId; self.tripId = tripId; self.flightNumber = flightNumber; self.airlineName = airlineName
        self.fromIATA = fromIATA; self.toIATA = toIATA; self.fromCity = fromCity; self.toCity = toCity
    }

    public init(flight: Flight, tripId: String) {
        self.init(
            flightId: flight.id,
            tripId: tripId,
            flightNumber: flight.flightNumber,
            airlineName: flight.airline?.name,
            fromIATA: flight.departure.code,
            toIATA: flight.arrival.code,
            fromCity: flight.departure.city ?? flight.departure.name,
            toCity: flight.arrival.city ?? flight.arrival.name
        )
    }
}
#endif
