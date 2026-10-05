import MapKit
import SummaryKit
import SwiftUI
import Testing
@testable import summary_chip

@MainActor
@Suite struct TripMapCameraTests {
    private let document = TripDocument(
        title: "Test",
        startDate: "2026-10-10",
        endDate: "2026-10-11",
        timeZone: "Asia/Tokyo",
        places: [
            TripPlace(id: "a", name: "A", coordinate: TripCoordinate(lat: 35.68, lng: 139.76)),
            TripPlace(id: "b", name: "B", coordinate: TripCoordinate(lat: 38.26, lng: 140.88)),
        ],
        days: [
            TripDay(id: "d1", date: "2026-10-10", title: "Go", route: TripDayRoute(kind: .out, placeIds: ["a", "b"])),
            TripDay(id: "d2", date: "2026-10-11", title: "Stay", route: TripDayRoute(kind: .stay, placeIds: ["b"])),
        ]
    )

    /// The route lands centred in the part of the map above the sheet.
    @Test func fitsDayAboveTheSheet() throws {
        let camera = TripMapCamera()
        camera.viewSize = CGSize(width: 400, height: 800)
        camera.obscured = EdgeInsets(top: 100, leading: 0, bottom: 400, trailing: 0)
        camera.show(dayID: "d1", in: document, animated: false)
        let rect = try #require(camera.position.rect)
        let route = try #require(TripMapCamera.rect(around: document.routeCoordinates(for: document.days[0]), minimumMeters: 25_000))
        // Visible area is y 100…400, so the route centres at y = 250 on screen.
        let scale = rect.width / 400
        #expect(abs(rect.height / scale - 800) < 0.5)
        let routeCenterY = (route.midY - rect.minY) / scale
        #expect(abs(routeCenterY - 250) < 1)
        #expect(route.minY >= rect.minY && route.maxY <= rect.maxY)
    }

    @Test func pausesAfterUserGestureAndResumes() {
        let camera = TripMapCamera()
        camera.viewSize = CGSize(width: 400, height: 800)
        camera.userMoved()
        #expect(!camera.following)
        camera.show(dayID: "d2", in: document, animated: false)
        #expect(camera.position.rect == nil)
        camera.resumeFollowing(dayID: "d2", in: document)
        #expect(camera.following)
        #expect(camera.position.rect != nil)
    }

    @Test func freezesWhileDiaryCoversMap() {
        let camera = TripMapCamera()
        camera.viewSize = CGSize(width: 400, height: 800)
        camera.frozen = true
        camera.show(dayID: "d1", in: document, animated: false)
        #expect(camera.position.rect == nil)
    }
}
