import MapKit
import Observation
import SummaryKit

/// Resolve explicit landmark cues once near their saved area, never by parsing spoken text.
@MainActor @Observable
final class TripTourLandmarks {
    private var coordinates: [String: TripCoordinate] = [:]
    private var unavailable: Set<String> = []

    func coordinate(for landmark: TripTourLandmark, in document: TripDocument) -> TripCoordinate? {
        coordinates[key(landmark, document)]
    }

    func resolve(_ landmarks: [TripTourLandmark], in document: TripDocument) async {
        for landmark in landmarks {
            guard !Task.isCancelled else { return }
            let key = key(landmark, document)
            guard coordinates[key] == nil, !unavailable.contains(key), let area = document.place(id: landmark.nearPlaceId) else { continue }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = landmark.name
            request.region = MKCoordinateRegion(center: area.coordinate.clCoordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
            // Address matching can reduce "Nezu Museum, Tokyo" to the unrelated Nezu district.
            // The region provides the area; only landmark results may become a map pin.
            request.resultTypes = .pointOfInterest
            let search = MKLocalSearch(request: request)
            do {
                let result = try await withTaskCancellationHandler { try await search.start() } onCancel: { search.cancel() }
                guard !Task.isCancelled else { return }
                // Search regions are hints; exclude distant namesakes rather than flying abroad.
                let origin = CLLocation(latitude: area.coordinate.lat, longitude: area.coordinate.lng)
                if let item = result.mapItems.first(where: { origin.distance(from: $0.location) <= 50_000 }) {
                    coordinates[key] = TripCoordinate(lat: item.location.coordinate.latitude, lng: item.location.coordinate.longitude)
                } else {
                    unavailable.insert(key)
                }
            } catch {
                guard !Task.isCancelled else { return }
                unavailable.insert(key)
            }
        }
    }

    private func key(_ landmark: TripTourLandmark, _ document: TripDocument) -> String {
        let area = document.place(id: landmark.nearPlaceId)
        return "\(landmark.name)|\(area?.coordinate.lat ?? 0)|\(area?.coordinate.lng ?? 0)"
    }
}

/// The photo subject can have a saved place, a resolved landmark, or images alone.
struct TripTourSpotlight {
    var id: String
    var name: String
    var symbol: String
    var photos: [TripPhoto]
    var coordinate: TripCoordinate?

    init?(scene: TripTourScene?, focus: TripTourFocus?, document: TripDocument, landmarks: TripTourLandmarks) {
        guard let focus else { return nil }
        let place = document.place(id: focus.placeId)
        let landmark = scene?.landmarks?.first { $0.id == focus.landmarkId }
        let group = scene?.imageGroups?.first { $0.id == focus.imageGroupId }
        guard place != nil || landmark != nil || group != nil else { return nil }
        id = landmark?.id ?? place?.id ?? group?.id ?? ""
        name = landmark?.name ?? place?.name ?? group?.title ?? ""
        symbol = place?.kind.systemImage ?? "photo.on.rectangle.angled"
        photos = group?.photos ?? place?.photos ?? []
        coordinate = landmark.flatMap { landmarks.coordinate(for: $0, in: document) } ?? (landmark == nil ? place?.coordinate : nil)
    }
}
