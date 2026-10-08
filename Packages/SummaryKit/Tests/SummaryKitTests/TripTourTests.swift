import Foundation
import Testing
@testable import SummaryKit

@Suite struct TripTourTests {
    @Test func customGalleryFollowsMuseumStoryWithoutASavedMuseumPlace() throws {
        let scene = try SummaryJSON.decoder().decode(TripTourScene.self, from: Data(#"""
        {"kind":"day","dayId":"d2","title":"Aoyama","narration":"Explore the museum. Walk its garden. Return to Tokyo.","audioPath":"/audio",
         "landmarks":[{"id":"landmark-1","name":"Nezu Museum","nearPlaceId":"tokyo"}],
         "imageGroups":[{"id":"aoyama:gallery","title":"Aoyama architecture","dayId":"d2","photos":[
           {"url":"https://example.com/entrance.jpg","caption":"Nezu entrance","credit":"A"},
           {"url":"https://example.com/garden.jpg","caption":"Nezu garden","credit":"B"}]}],
         "visuals":[{"textOffset":0,"landmarkId":"landmark-1","imageGroupId":"aoyama:gallery"},
           {"textOffset":20,"landmarkId":"landmark-1","imageGroupId":"aoyama:gallery","photoIndex":1},
           {"textOffset":37,"placeId":"tokyo"}]}
        """#.utf8))
        let doc = TripDocument(title: "Tokyo", startDate: "2026-10-11", endDate: "2026-10-11", places: [
            TripPlace(id: "tokyo", name: "Tokyo", coordinate: TripCoordinate(lat: 35.685, lng: 139.7514)),
        ])
        let timeline = TripTourVisualTimeline(scene: scene, document: doc)
        #expect(doc.place(id: "landmark-1") == nil)
        #expect(timeline.focus(at: 0)?.landmarkId == "landmark-1")
        #expect(timeline.focus(at: 0)?.imageGroupId == "aoyama:gallery")
        #expect(timeline.focus(at: 0.6)?.photo(atCount: 2) == 1)
        #expect(timeline.focus(at: 0.95)?.placeId == "tokyo")
        #expect(timeline.focus(at: 0.95)?.imageGroupId == nil)
        #expect(timeline.focus(at: 0.1)?.photo(atCount: 2) == 0)
        #expect(scene.imageGroups?.first?.photos.last?.credit == "B")
    }

    @Test func imagesCanAppearWithoutAPlaceOrMapCoordinate() {
        let group = TripTourImageGroup(id: "gallery", title: "Garden", photos: [TripPhoto(url: "https://example.com/garden.jpg")])
        let scene = TripTourScene(kind: .day, title: "Garden", narration: "Let's look at the garden.", audioPath: "/audio", visuals: [
            TripTourVisual(textOffset: 0, photoIndex: 0, imageGroupId: "gallery"),
            TripTourVisual(textOffset: 20, imageGroupId: "missing"),
        ], imageGroups: [group])
        let focus = TripTourVisualTimeline(scene: scene, document: document).focus(at: 0.9)
        #expect(focus?.placeId == nil)
        #expect(focus?.landmarkId == nil)
        #expect(focus?.imageGroupId == "gallery")
        #expect(focus?.photo(atCount: 1) == 0)
    }

    private var document: TripDocument {
        TripDocument(title: "Tokyo", startDate: "2026-10-12", endDate: "2026-10-12", places: [
            TripPlace(id: "design", name: "21_21 DESIGN SIGHT", coordinate: TripCoordinate(lat: 35.666, lng: 139.73), photos: [
                TripPhoto(url: "https://example.com/building.jpg"), TripPhoto(url: "https://example.com/exhibition.jpg"), TripPhoto(url: "https://example.com/gallery.jpg"),
            ]),
            TripPlace(id: "park", name: "Hinokicho Park", coordinate: TripCoordinate(lat: 35.667, lng: 139.73), photos: [
                TripPhoto(url: "https://example.com/park.jpg"), TripPhoto(url: "https://example.com/pond.jpg"),
            ]),
        ], days: [TripDay(id: "d1", date: "2026-10-12", title: "Design and gardens", route: TripDayRoute(kind: .stay, placeIds: ["design", "park"]))])
    }

    @Test func followsPlacesInTranslatedDayNarrationAndCyclesPhotos() throws {
        let text = "2026年10月12日。今天我们探索东京 🗼。随后在21_21 DESIGN SIGHT体会设计展览的细节，再到桧町公园散步，让绿意为城市节奏留出空隙。"
        let firstOffset = text[..<(try #require(text.range(of: "21_21")).lowerBound)].utf16.count
        let secondOffset = text[..<(try #require(text.range(of: "桧町公园")).lowerBound)].utf16.count
        let scene = TripTourScene(kind: .day, dayId: "d1", title: "Tokyo", narration: text, audioPath: "/audio", visuals: [
            TripTourVisual(textOffset: firstOffset, placeId: "design"),
            TripTourVisual(textOffset: secondOffset, placeId: "park", photoIndex: 1),
        ])
        let timeline = TripTourVisualTimeline(scene: scene, document: document)
        let first = Double(firstOffset) / Double(text.utf16.count)
        let second = Double(secondOffset) / Double(text.utf16.count)
        #expect(timeline.focus(at: 0) == nil)
        let middle = try #require(timeline.focus(at: (first + second) / 2))
        #expect(middle.placeId == "design")
        #expect(middle.photo(atCount: 3) == 1)
        let park = try #require(timeline.focus(at: second + 0.01))
        #expect(park.placeId == "park")
        #expect(park.photo(atCount: 2) == 1)
        // Seeking back restores the earlier place and image; pausing has no independent timer.
        #expect(timeline.focus(at: first + 0.01)?.placeId == "design")
        #expect(timeline.focus(at: first + 0.01)?.photo(atCount: 3) == 0)
    }

    @Test func changesImagesWhenTheirSubjectsAreDiscussed() {
        let text = "The building has an angular roof. Inside, the exhibition explores everyday design."
        let scene = TripTourScene(kind: .place, placeId: "design", title: "Design", narration: text, audioPath: "/audio", visuals: [
            TripTourVisual(textOffset: 0, placeId: "design", photoIndex: 0),
            TripTourVisual(textOffset: 33, placeId: "design", photoIndex: 1),
        ])
        let timeline = TripTourVisualTimeline(scene: scene, document: document)
        #expect(timeline.focus(at: 0)?.photo(atCount: 3) == 0)
        #expect(timeline.focus(at: 0.75)?.photo(atCount: 3) == 1)
    }

    @Test func olderToursDecodeAndStillShowPlacesAndPhotos() throws {
        let scene = try SummaryJSON.decoder().decode(TripTourScene.self, from: Data(#"{"kind":"place","placeId":"design","title":"Design","narration":"Explore the museum.","audioPath":"/audio"}"#.utf8))
        #expect(scene.visuals == nil)
        let timeline = TripTourVisualTimeline(scene: scene, document: document)
        #expect(timeline.focus(at: 0)?.placeId == "design")
        #expect(timeline.focus(at: 0.9)?.photo(atCount: 3) == 2)
        #expect(timeline.focus(at: 1)?.photo(atCount: 0) == nil)
    }

    @Test func ignoresInvalidCommandsWithoutMatchingPlaceNamesInSpeech() {
        let scene = TripTourScene(kind: .day, dayId: "d1", title: "Tokyo", narration: "Next, explore Hinokicho Park.", audioPath: "/audio", visuals: [
            TripTourVisual(textOffset: 0, placeId: "missing"),
            TripTourVisual(textOffset: -1, placeId: "design"),
            TripTourVisual(textOffset: 999, placeId: "park"),
        ])
        let timeline = TripTourVisualTimeline(scene: scene, document: document)
        #expect(timeline.focus(at: 0) == nil)
        #expect(timeline.focus(at: 0.9) == nil)
    }

    @Test func olderPhraseCuesDecodeWithoutParsingProse() throws {
        let scene = try SummaryJSON.decoder().decode(TripTourScene.self, from: Data(#"{"kind":"day","title":"Park","narration":"Hinokicho Park","audioPath":"/audio","visuals":[{"phrase":"Hinokicho Park","placeId":"park"}]}"#.utf8))
        #expect(TripTourVisualTimeline(scene: scene, document: document).focus(at: 1) == nil)
    }
}
