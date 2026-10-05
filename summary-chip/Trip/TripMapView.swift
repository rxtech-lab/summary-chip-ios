import MapKit
import Observation
import SummaryKit
import SwiftUI

/// The map's camera: follows the day being read, shows the whole trip, or stays where the user
/// moved it. Fits routes into the part of the map not covered by the navigation bar or the diary sheet.
@Observable
final class TripMapCamera {
    var position: MapCameraPosition = .automatic
    /// Moves with the diary. A map gesture turns it off; "Follow" turns it back on.
    var following = true
    /// Showing every route at once ("Whole trip").
    private(set) var overview = false
    /// The diary covers the map (iPhone sheet at full height): keep the camera still.
    var frozen = false
    /// The map's full size, and how much of each edge is covered.
    var viewSize: CGSize = .zero
    var obscured = EdgeInsets()
    @ObservationIgnored private var lastKey: String?

    private static let padding: CGFloat = 36

    /// Frames a day: its route, or the area around where it stays. Skips repeats unless `force`.
    func show(dayID: String?, in document: TripDocument, force: Bool = false, animated: Bool = true) {
        guard following, !frozen, let day = document.day(id: dayID) else { return }
        overview = false
        let coordinates = document.focusCoordinates(for: day)
        let key = "\(day.id):\(coordinates.count)"
        guard force || key != lastKey else { return }
        guard let rect = Self.rect(around: coordinates, minimumMeters: coordinates.count > 1 ? 25_000 : 40_000) else { return }
        lastKey = key
        move(to: rect, animated: animated)
    }

    /// Fits every place and route.
    func showWholeTrip(_ document: TripDocument) {
        following = false
        overview = true
        lastKey = nil
        let coordinates = document.places.map(\.coordinate) + document.days.flatMap { document.routeCoordinates(for: $0) }
        guard let rect = Self.rect(around: coordinates, minimumMeters: 50_000) else { return }
        move(to: rect, animated: true)
    }

    func resumeFollowing(dayID: String?, in document: TripDocument) {
        following = true
        overview = false
        show(dayID: dayID, in: document, force: true)
    }

    func center(on coordinate: CLLocationCoordinate2D) {
        following = false
        overview = false
        lastKey = nil
        guard let rect = Self.rect(around: [TripCoordinate(coordinate)], minimumMeters: 8_000) else { return }
        move(to: rect, animated: true)
    }

    /// A map gesture took over.
    func userMoved() {
        following = false
        lastKey = nil
    }

    private func move(to rect: MKMapRect, animated: Bool) {
        let target = MapCameraPosition.rect(fitted(rect))
        if animated {
            withAnimation(.easeInOut(duration: 0.55)) { position = target }
        } else {
            position = target
        }
    }

    /// Grows `rect` so that, shown on the whole map, it lands centred in the uncovered area.
    private func fitted(_ rect: MKMapRect) -> MKMapRect {
        let width = viewSize.width, height = viewSize.height
        let pad = Self.padding
        let visibleWidth = width - obscured.leading - obscured.trailing - pad * 2
        let visibleHeight = height - obscured.top - obscured.bottom - pad * 2
        guard width > 0, height > 0, visibleWidth > 40, visibleHeight > 40 else {
            return rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
        }
        let scale = max(rect.width / visibleWidth, rect.height / visibleHeight)
        let centerX = obscured.leading + pad + visibleWidth / 2
        let centerY = obscured.top + pad + visibleHeight / 2
        return MKMapRect(
            x: rect.midX - centerX * scale,
            y: rect.midY - centerY * scale,
            width: width * scale,
            height: height * scale
        )
    }

    /// The bounding map rect of `coordinates`, at least `minimumMeters` across.
    static func rect(around coordinates: [TripCoordinate], minimumMeters: Double) -> MKMapRect? {
        guard let first = coordinates.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first.clCoordinate), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate.clCoordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let minimum = minimumMeters * MKMapPointsPerMeterAtLatitude(first.lat)
        let dx = max(0, (minimum - rect.width) / 2), dy = max(0, (minimum - rect.height) / 2)
        return rect.insetBy(dx: -dx, dy: -dy)
    }
}

/// Every day's route in its colour (earlier days strong, later ones faint), the day being read
/// drawn up to the traveler, places marked active / visited, and the user's location.
struct TripMapView: View {
    let document: TripDocument
    let activeDayID: String?
    let progress: Double
    @Bindable var camera: TripMapCamera
    let location: LocationProvider
    var onSelectPlace: (TripPlace) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct DayLine: Identifiable {
        var id: String
        var coordinates: [CLLocationCoordinate2D]
        var kind: TripRouteKind?
        var opacity: Double
    }

    private struct ActiveRoute {
        var trail: [CLLocationCoordinate2D]
        var line: [CLLocationCoordinate2D]
        var kind: TripRouteKind?
        var returning: Bool
        var traveler: CLLocationCoordinate2D?
    }

    private var orderedDays: [TripDay] { document.orderedDays }

    private var activeIndex: Int? {
        orderedDays.firstIndex { $0.id == activeDayID }
    }

    private var dayLines: [DayLine] {
        let active = activeIndex ?? 0
        return orderedDays.enumerated().compactMap { index, day in
            let coordinates = document.routeCoordinates(for: day)
            guard coordinates.count >= 2 else { return nil }
            let opacity = camera.overview ? 0.78 : (index < active ? 0.72 : 0.1)
            return DayLine(id: day.id, coordinates: coordinates.map(\.clCoordinate), kind: day.route?.kind, opacity: opacity)
        }
    }

    private var activeRoute: ActiveRoute? {
        guard !camera.overview, let index = activeIndex else { return nil }
        let day = orderedDays[index]
        let points = document.routeCoordinates(for: day)
        guard points.count >= 2 else { return nil }
        let geometry = TripRouteGeometry(points: points)
        guard let sample = geometry.sample(progress: reduceMotion ? 1 : progress) else { return nil }
        // A side trip out and back: draw the way back dashed over the faded way out.
        let returning = day.route?.kind == .side && points.count == 3 && sample.segment == 2
        return ActiveRoute(
            trail: returning ? points.prefix(2).map(\.clCoordinate) : [],
            line: returning ? [points[1].clCoordinate, sample.point.clCoordinate] : sample.path.map(\.clCoordinate),
            kind: day.route?.kind,
            returning: returning,
            traveler: reduceMotion ? nil : sample.point.clCoordinate
        )
    }

    private var activePlaceIDs: Set<String> {
        guard let day = document.day(id: activeDayID) else { return [] }
        return Set(document.placeIDs(for: day))
    }

    private var visitedPlaceIDs: Set<String> {
        guard let index = activeIndex else { return [] }
        return Set(orderedDays.prefix(index).flatMap { document.placeIDs(for: $0) })
    }

    var body: some View {
        let active = activeRoute
        let activeIDs = activePlaceIDs
        let visitedIDs = visitedPlaceIDs
        Map(position: $camera.position) {
            UserAnnotation()
            ForEach(dayLines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(TripStyle.color(for: line.kind).opacity(line.opacity), style: TripStyle.stroke(for: line.kind))
            }
            if let active {
                if !active.trail.isEmpty {
                    MapPolyline(coordinates: active.trail)
                        .stroke(TripStyle.color(for: active.kind).opacity(0.38), style: TripStyle.stroke(for: active.kind, width: 6))
                }
                MapPolyline(coordinates: active.line)
                    .stroke(TripStyle.color(for: active.kind), style: TripStyle.stroke(for: active.kind, width: 6, returning: active.returning))
            }
            ForEach(document.places) { place in
                Annotation(place.name, coordinate: place.coordinate.clCoordinate, anchor: .center) {
                    PlaceDot(major: place.major, active: activeIDs.contains(place.id), visited: visitedIDs.contains(place.id))
                        .onTapGesture { onSelectPlace(place) }
                        .accessibilityAddTraits(.isButton)
                }
                .annotationTitles(place.major || activeIDs.contains(place.id) ? .visible : .hidden)
            }
            if let traveler = active?.traveler {
                Annotation("", coordinate: traveler, anchor: .center) {
                    TravelerDot()
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapScaleView()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { camera.viewSize = $0 }
        .onChange(of: camera.position.positionedByUser) { _, byUser in
            if byUser { camera.userMoved() }
        }
        .accessibilityIdentifier("trip-map")
    }
}

/// Follow / Whole trip / Locate me, top-trailing over the map.
struct TripMapControls: View {
    let following: Bool
    let overview: Bool
    let onFollow: () -> Void
    let onWholeTrip: () -> Void
    let onLocate: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                Button(action: onFollow) {
                    Label(following ? String(localized: "Following") : String(localized: "Follow"),
                          systemImage: following ? "location.north.line.fill" : "location.north.line")
                }
                .accessibilityIdentifier("trip-map-follow")
                Button(action: onWholeTrip) {
                    Label("Whole trip", systemImage: overview ? "map.fill" : "map")
                }
                .accessibilityIdentifier("trip-map-overview")
                Button(action: onLocate) {
                    Label("Locate me", systemImage: "location")
                }
                .accessibilityIdentifier("trip-map-locate")
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: following)
    }
}

private struct PlaceDot: View {
    let major: Bool
    let active: Bool
    let visited: Bool

    var body: some View {
        let size: CGFloat = major ? 17 : 12
        Circle()
            .fill(active ? TripStyle.color(for: .out) : (visited ? Color(white: 0.35) : .white))
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(active ? .white : Color(white: 0.3), lineWidth: active ? 3 : 2) }
            .scaleEffect(active ? 1.25 : 1)
            .shadow(color: .black.opacity(0.25), radius: active ? 4 : 1.5, y: 1)
            .animation(.spring(duration: 0.35), value: active)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}

private struct TravelerDot: View {
    var body: some View {
        Circle()
            .fill(TripStyle.traveler)
            .frame(width: 18, height: 18)
            .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .accessibilityHidden(true)
    }
}
