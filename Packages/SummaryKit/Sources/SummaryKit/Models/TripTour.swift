import Foundation

/// A trip played as narrated scenes over the map (play mode). Spec: `docs/tours.md`.
public struct TripTour: Codable, Sendable, Hashable {
    /// Names this version of the tour (the trip as followed, its language and voice).
    public var key: String
    public var language: String
    public var voice: String
    public var createdAt: Date
    public var scenes: [TripTourScene]

    public init(key: String, language: String, voice: String, createdAt: Date = .now, scenes: [TripTourScene]) {
        self.key = key
        self.language = language
        self.voice = voice
        self.createdAt = createdAt
        self.scenes = scenes
    }
}

public enum TripTourSceneKind: String, TripLenientEnum {
    case intro, day, travel, place, stay, outro, unknown
    public static let fallback: Self = .unknown
}

/// One stop of a tour: what the map shows, the caption and what the narrator says.
public struct TripTourScene: Codable, Sendable, Hashable {
    public var kind: TripTourSceneKind
    public var dayId: String?
    /// The place the camera visits (`place`, and `stay` when the hotel has a place).
    public var placeId: String?
    /// The transport being ridden (`travel`).
    public var transportId: String?
    /// The hotel of the night (`stay`).
    public var hotelId: String?
    public var title: String
    /// Spoken, and shown as subtitles.
    public var narration: String
    /// Place and photo commands compiled to positions in the clean narration. Older tours may omit them.
    public var visuals: [TripTourVisual]?
    public var imageGroups: [TripTourImageGroup]?
    public var landmarks: [TripTourLandmark]?
    /// Where the narration's MP3 is, relative to the API origin.
    public var audioPath: String

    public init(kind: TripTourSceneKind, dayId: String? = nil, placeId: String? = nil, transportId: String? = nil, hotelId: String? = nil, title: String, narration: String, audioPath: String, visuals: [TripTourVisual]? = nil, imageGroups: [TripTourImageGroup]? = nil, landmarks: [TripTourLandmark]? = nil) {
        self.kind = kind
        self.dayId = dayId
        self.placeId = placeId
        self.transportId = transportId
        self.hotelId = hotelId
        self.title = title
        self.narration = narration
        self.visuals = visuals
        self.imageGroups = imageGroups
        self.landmarks = landmarks
        self.audioPath = audioPath
    }
}
