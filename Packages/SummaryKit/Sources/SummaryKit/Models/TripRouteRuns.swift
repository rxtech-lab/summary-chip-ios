import Foundation

/// How a stretch of a day's route is travelled, which decides what the map snaps it to.
public enum TripRouteTravel: String, Sendable, Hashable {
    /// Along roads (car, bus, or unknown ground travel).
    case road
    case walk
    /// Along railway tracks.
    case rail
    /// A straight line: flights, ferries, or when nothing better is known.
    case direct

    init(_ mode: TripSegmentMode) {
        switch mode {
        case .train: self = .rail
        case .car, .bus: self = .road
        case .walk: self = .walk
        case .flight, .ferry, .other: self = .direct
        }
    }
}

/// Consecutive waypoints of a day's route travelled the same way; routed as one request.
public struct TripRouteRun: Sendable, Hashable {
    public var travel: TripRouteTravel
    /// At least two.
    public var points: [TripCoordinate]

    public init(travel: TripRouteTravel, points: [TripCoordinate]) {
        self.travel = travel
        self.points = points
    }
}

public extension TripDocument {
    /// A day's route waypoints split into runs by how each leg is travelled, so the map can follow
    /// roads and railway tracks. Each leg takes the mode of the transport segment between its two
    /// places, else the mode every segment of the day shares, else road (straight for ferry days).
    func routeRuns(for day: TripDay) -> [TripRouteRun] {
        let points = routeCoordinates(for: day)
        guard points.count >= 2, let kind = day.route?.kind else { return [] }
        let segments = day.transportIds.compactMap { transport(id: $0)?.selectedOption }.flatMap(\.segments)
        let modes = Set(segments.map(\.mode))
        let dayTravel: TripRouteTravel = if kind == .ferry {
            .direct
        } else if modes.count == 1, let mode = modes.first {
            TripRouteTravel(mode)
        } else {
            .road
        }
        let placeIDs = points.map { nearbyPlaceID(to: $0) }
        var runs: [TripRouteRun] = []
        for index in points.indices.dropFirst() {
            var segment: TripSegment?
            if let from = placeIDs[index - 1], let to = placeIDs[index] {
                segment = segments.first { $0.fromPlaceId == from && $0.toPlaceId == to }
                    ?? segments.first { $0.fromPlaceId == to && $0.toPlaceId == from }
            }
            let travel = segment.map { TripRouteTravel($0.mode) } ?? dayTravel
            if runs.last?.travel == travel {
                runs[runs.count - 1].points.append(points[index])
            } else {
                runs.append(TripRouteRun(travel: travel, points: [points[index - 1], points[index]]))
            }
        }
        return runs
    }

    /// The place a route waypoint marks, if one is within `radius` metres.
    private func nearbyPlaceID(to coordinate: TripCoordinate, radius: Double = 1_000) -> String? {
        places
            .map { ($0.id, $0.coordinate.distance(to: coordinate)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }
}
