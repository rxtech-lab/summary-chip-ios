import Foundation

/// A day's route measured along the great circle, so a traveler can be placed at any fraction of it.
/// Port of `measureRoute` / `sampleRoute` from the Northbound diary.
public struct TripRouteGeometry: Sendable, Hashable {
    /// Where the traveler is and the part of the route already travelled.
    public struct Sample: Sendable, Hashable {
        public var point: TripCoordinate
        /// From the start to `point`, inclusive.
        public var path: [TripCoordinate]
        /// Index of the point the traveler is heading to (the last index once arrived).
        public var segment: Int
    }

    public let points: [TripCoordinate]
    /// Cumulative angular length (radians on the unit sphere) at each point; `lengths[0] == 0`.
    public let lengths: [Double]

    public var total: Double { lengths.last ?? 0 }
    /// The route's length in metres.
    public var totalMeters: Double { total * 6_371_008.8 }

    public init(points: [TripCoordinate]) {
        self.points = points
        var lengths: [Double] = points.isEmpty ? [] : [0]
        let r = Double.pi / 180
        for i in points.indices.dropFirst() {
            let a = points[i - 1], b = points[i]
            let h = pow(sin((b.lat - a.lat) * r / 2), 2)
                + cos(a.lat * r) * cos(b.lat * r) * pow(sin((b.lng - a.lng) * r / 2), 2)
            lengths.append(lengths[i - 1] + 2 * atan2(sqrt(h), sqrt(max(0, 1 - h))))
        }
        self.lengths = lengths
    }

    public static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }

    /// The traveler `progress` (0…1) of the way along. Nil for an empty route without `fallback`.
    public func sample(progress: Double, fallback: TripCoordinate? = nil) -> Sample? {
        guard let first = points.first else {
            return fallback.map { Sample(point: $0, path: [], segment: 0) }
        }
        let distance = total * Self.clamp(progress)
        var path = [first]
        for i in points.indices.dropFirst() {
            if distance >= lengths[i] {
                path.append(points[i])
                continue
            }
            let length = lengths[i] - lengths[i - 1]
            let part = length > 0 ? (distance - lengths[i - 1]) / length : 0
            let a = points[i - 1], b = points[i]
            let point = TripCoordinate(lat: a.lat + (b.lat - a.lat) * part, lng: a.lng + (b.lng - a.lng) * part)
            path.append(point)
            return Sample(point: point, path: path, segment: i)
        }
        return Sample(point: points[points.count - 1], path: path, segment: points.count - 1)
    }
}

/// Which diary day is being read and how far into it, from the day cards' positions and a reading
/// line (all in the scroll content's coordinates). Port of the Northbound `readDay()`.
public enum TripReading {
    public struct Position: Sendable, Hashable {
        public var index: Int
        public var progress: Double
    }

    /// `frames` are the day cards top to bottom as `(minY, maxY)`. The active card is the last whose
    /// top has passed the line; progress runs from its top to the next card's top.
    public static func position(frames: [(minY: Double, maxY: Double)], line: Double) -> Position? {
        guard !frames.isEmpty else { return nil }
        var index = 0
        for (i, frame) in frames.enumerated() {
            if frame.minY <= line { index = i } else { break }
        }
        let start = frames[index].minY
        let end = index + 1 < frames.count ? frames[index + 1].minY : frames[index].maxY
        let progress = TripRouteGeometry.clamp((line - start) / max(1, end - start))
        return Position(index: index, progress: progress)
    }
}
