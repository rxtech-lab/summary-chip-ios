import Foundation

/// A gallery from the rendered custom trip UI, with its original captions and credits.
public struct TripTourImageGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var dayId: String?
    public var photos: [TripPhoto]

    public init(id: String, title: String, dayId: String? = nil, photos: [TripPhoto]) {
        self.id = id
        self.title = title
        self.dayId = dayId
        self.photos = photos
    }
}

/// A named itinerary landmark whose coordinate will be resolved near a saved city or area.
public struct TripTourLandmark: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var nearPlaceId: String

    public init(id: String, name: String, nearPlaceId: String) {
        self.id = id
        self.name = name
        self.nearPlaceId = nearPlaceId
    }
}

/// A compiled command's position in clean speech. Photos belong to its image group or saved place.
public struct TripTourVisual: Codable, Sendable, Hashable {
    /// UTF-16 code units before this command. Optional so old phrase-based cues still decode.
    public var textOffset: Int?
    public var placeId: String?
    public var landmarkId: String?
    public var imageGroupId: String?
    public var photoIndex: Int?

    public init(textOffset: Int, placeId: String? = nil, photoIndex: Int? = nil, landmarkId: String? = nil, imageGroupId: String? = nil) {
        self.textOffset = textOffset
        self.placeId = placeId
        self.photoIndex = photoIndex
        self.landmarkId = landmarkId
        self.imageGroupId = imageGroupId
    }
}

/// The place being discussed, and progress through its part of the narration.
public struct TripTourFocus: Sendable, Hashable {
    public var placeId: String?
    public var landmarkId: String?
    public var imageGroupId: String?
    public var photoIndex: Int?
    public var progress: Double

    public var destinationId: String? { landmarkId ?? placeId }

    /// A specific subject stays visible; otherwise the carousel progresses through all photos.
    public func photo(atCount count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let photoIndex, (0..<count).contains(photoIndex) { return photoIndex }
        return min(count - 1, Int(progress * Double(count)))
    }
}

/// Follow compiled command positions without parsing markers or matching spoken place names.
public struct TripTourVisualTimeline: Sendable {
    private struct Step: Sendable {
        var offset: Int
        var placeId: String?
        var landmarkId: String?
        var imageGroupId: String?
        var photoIndex: Int?
    }
    private var steps: [Step] = []
    private var length = 1

    public init() {}

    public init(scene: TripTourScene, document: TripDocument) {
        length = max(1, scene.narration.utf16.count)
        let places = Dictionary(document.places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary((scene.imageGroups ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let landmarks = Set((scene.landmarks ?? []).filter { places[$0.nearPlaceId] != nil }.map(\.id))
        let fallback = scene.placeId ?? document.hotel(id: scene.hotelId)?.placeId
        if [.place, .stay].contains(scene.kind), let fallback, places[fallback] != nil {
            steps.append(Step(offset: 0, placeId: fallback))
        }
        for visual in scene.visuals ?? [] {
            guard let offset = visual.textOffset,
                  (0...length).contains(offset) else { continue }
            let place = visual.placeId.flatMap { places[$0] }
            let landmark = visual.landmarkId.flatMap { landmarks.contains($0) ? $0 : nil }
            let group = visual.imageGroupId.flatMap { groups[$0] }
            guard place != nil || landmark != nil || group != nil else { continue }
            // A gallery can be shown without a map coordinate; do not pin it to a guessed city.
            let photos = group?.photos ?? place?.photos ?? []
            let photo = visual.photoIndex.flatMap { photos.indices.contains($0) ? $0 : nil }
            steps.append(Step(offset: offset, placeId: place?.id, landmarkId: landmark, imageGroupId: group?.id, photoIndex: photo))
        }
        let ordered = steps.enumerated().sorted {
            $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
        }.map(\.element)
        steps = ordered.reduce(into: []) { result, step in
            if result.last?.offset == step.offset { result.removeLast() }
            result.append(step)
        }
    }

    public func focus(at progress: Double) -> TripTourFocus? {
        let spoken = Double(length) * (progress.isFinite ? min(1, max(0, progress)) : 0)
        guard let index = steps.lastIndex(where: { Double($0.offset) <= spoken }) else { return nil }
        let step = steps[index]
        let end = index + 1 < steps.count ? steps[index + 1].offset : length
        let fraction = min(1, max(0, (spoken - Double(step.offset)) / Double(max(1, end - step.offset))))
        return TripTourFocus(placeId: step.placeId, landmarkId: step.landmarkId, imageGroupId: step.imageGroupId, photoIndex: step.photoIndex, progress: fraction)
    }
}
