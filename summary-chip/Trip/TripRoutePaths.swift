import Foundation
import MapKit
import Observation
import SummaryKit

/// Day routes snapped to what they travel on: roads and footpaths from MapKit, railway tracks from
/// the open OpenRailRouting service (OpenStreetMap data). Flights and ferries stay straight, and so
/// does any run that can't be routed. Snapped lines are kept on disk so each is fetched once.
@Observable
final class TripRoutePaths {
    static let shared = TripRoutePaths()

    private var paths: [String: [TripCoordinate]]
    @ObservationIgnored private var attempted: Set<String> = []

    private static let railURL = URL(string: "https://routing.openrailrouting.org/route")!
    private static let cacheURL = URL.cachesDirectory.appending(path: "trip-route-paths.json")

    init() {
        paths = (try? Data(contentsOf: Self.cacheURL)).flatMap { try? JSONDecoder().decode([String: [TripCoordinate]].self, from: $0) } ?? [:]
    }

    /// The run's snapped line once fetched, else its waypoints.
    func points(for run: TripRouteRun) -> [TripCoordinate] {
        paths[Self.key(for: run)] ?? run.points
    }

    /// Fetches every run not yet snapped, one at a time; each is tried once per launch.
    func resolve(_ runs: [TripRouteRun]) async {
        for run in runs where run.travel != .direct {
            let key = Self.key(for: run)
            guard paths[key] == nil, attempted.insert(key).inserted else { continue }
            do {
                let routed = try await route(run)
                guard Self.plausible(routed, for: run) else { continue }
                paths[key] = Self.simplified([run.points[0]] + routed + [run.points[run.points.count - 1]])
                save()
            } catch {
                // Cancelled runs are retried next time; failed ones stay straight until relaunch.
                if Task.isCancelled {
                    attempted.remove(key)
                    return
                }
            }
        }
    }

    private func route(_ run: TripRouteRun) async throws -> [TripCoordinate] {
        switch run.travel {
        case .rail: try await railRoute(run.points)
        case .road: try await mapKitRoute(run.points, transport: .automobile)
        case .walk: try await mapKitRoute(run.points, transport: .walking)
        case .direct: run.points
        }
    }

    /// MapKit routes two points at a time; the legs are joined.
    private func mapKitRoute(_ points: [TripCoordinate], transport: MKDirectionsTransportType) async throws -> [TripCoordinate] {
        var line: [TripCoordinate] = []
        for (from, to) in zip(points, points.dropFirst()) {
            let request = MKDirections.Request()
            request.source = MKMapItem(location: CLLocation(latitude: from.lat, longitude: from.lng), address: nil)
            request.destination = MKMapItem(location: CLLocation(latitude: to.lat, longitude: to.lng), address: nil)
            request.transportType = transport
            let response = try await MKDirections(request: request).calculate()
            guard let polyline = response.routes.first?.polyline else { throw URLError(.cannotParseResponse) }
            let buffer = UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount)
            line += buffer.map { TripCoordinate($0.coordinate) }
        }
        return line
    }

    /// One OpenRailRouting request through every waypoint.
    private func railRoute(_ points: [TripCoordinate]) async throws -> [TripCoordinate] {
        struct Response: Decodable {
            struct Path: Decodable {
                struct Line: Decodable { let coordinates: [[Double]] }
                let points: Line
            }
            let paths: [Path]
        }
        var components = URLComponents(url: Self.railURL, resolvingAgainstBaseURL: false)!
        components.queryItems = points.map { URLQueryItem(name: "point", value: "\($0.lat),\($0.lng)") } + [
            URLQueryItem(name: "profile", value: "all_tracks"),
            URLQueryItem(name: "points_encoded", value: "false"),
            URLQueryItem(name: "instructions", value: "false"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let coordinates = decoded.paths.first?.points.coordinates else { throw URLError(.cannotParseResponse) }
        // GeoJSON order: longitude, latitude.
        return coordinates.compactMap { $0.count >= 2 ? TripCoordinate(lat: $0[1], lng: $0[0]) : nil }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private static func key(for run: TripRouteRun) -> String {
        run.travel.rawValue + ":" + run.points.map { String(format: "%.4f,%.4f", $0.lat, $0.lng) }.joined(separator: ";")
    }

    /// Rejects lines that start or end far from the waypoints, or wander far longer than the
    /// straight route (snapped to the wrong network).
    private static func plausible(_ line: [TripCoordinate], for run: TripRouteRun) -> Bool {
        guard let first = line.first, let last = line.last, let start = run.points.first, let end = run.points.last else { return false }
        guard first.distance(to: start) < 5_000, last.distance(to: end) < 5_000 else { return false }
        let straight = TripRouteGeometry(points: run.points).totalMeters
        let routed = TripRouteGeometry(points: line).totalMeters
        return routed <= max(straight * (run.travel == .rail ? 3 : 4), straight + 5_000)
    }

    /// Douglas–Peucker in degrees (about 15 m), so long lines stay light to draw and animate.
    private static func simplified(_ line: [TripCoordinate], tolerance: Double = 0.00015) -> [TripCoordinate] {
        guard line.count > 2 else { return line }
        var keep = [Bool](repeating: false, count: line.count)
        keep[0] = true
        keep[line.count - 1] = true
        var stack = [(0, line.count - 1)]
        while let (start, end) = stack.popLast() {
            let a = line[start], b = line[end]
            let dx = b.lng - a.lng, dy = b.lat - a.lat
            let length = (dx * dx + dy * dy).squareRoot()
            var farthest = start, distance = 0.0
            for index in (start + 1)..<end {
                let p = line[index]
                let d = length > 0
                    ? abs(dy * (p.lng - a.lng) - dx * (p.lat - a.lat)) / length
                    : ((p.lng - a.lng) * (p.lng - a.lng) + (p.lat - a.lat) * (p.lat - a.lat)).squareRoot()
                if d > distance { farthest = index; distance = d }
            }
            if distance > tolerance {
                keep[farthest] = true
                if farthest - start > 1 { stack.append((start, farthest)) }
                if end - farthest > 1 { stack.append((farthest, end)) }
            }
        }
        return line.indices.filter { keep[$0] }.map { line[$0] }
    }
}
