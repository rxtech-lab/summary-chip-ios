import CoreLocation
import Foundation
import Testing
@testable import SummaryKit

private struct TripEnvelope: Decodable { let trip: Trip }

private func loadTrip() throws -> Trip {
    try SummaryJSON.decoder().decode(TripEnvelope.self, from: fixture("trip.json")).trip
}

@Suite struct TripDecodingTests {
    @Test func decodesTripDocument() throws {
        let trip = try loadTrip()
        #expect(trip.id == "trip_01")
        #expect(trip.revision == 3)
        #expect(trip.visibility == .private)
        let doc = trip.document
        #expect(doc.timeZone == "Asia/Tokyo")
        #expect(doc.currency == "JPY")
        #expect(doc.places.count == 4)
        #expect(doc.places[0].major == false) // absent → default
        #expect(doc.places[3].kind == .poi) // unknown → default
        #expect(doc.days[1].highlight)
        #expect(doc.days[1].moments[0].slot == .morning) // unknown slot → fallback
        #expect(doc.days[2].transportIds.isEmpty) // absent → []
        #expect(doc.notes.isEmpty && doc.sources.isEmpty)
        let late = try #require(doc.transport(id: "t-hayabusa")?.selectedOption)
        #expect(late.id == "late")
        #expect(late.segments[0].train?.category == .other) // unknown → default
        #expect(late.segments[0].train?.seatClass == nil) // unknown optional → nil
        #expect(doc.transport(id: "t-nex")?.options[0].segments[0].train?.category == .limitedExpress)
        #expect(doc.transport(id: "t-hayabusa")?.status == .planned)
        #expect(TripDate.clock(late.effectiveDeparture) == "09:36")
    }

    @Test func summaryKindDefaultsToSummary() throws {
        let summary = try SummaryJSON.decoder().decode(Summary.self, from: fixture("summary.json"))
        #expect(summary.kind == .summary)
        #expect(SummaryKind(rawValue: "trip") == .trip)
        #expect(SummaryKind(rawValue: "album") == .other("album"))
    }

    @Test func encodesOperationsWithDiscriminator() throws {
        let data = try SummaryJSON.encoder().encode([
            TripOperation.delete(.hotels, id: "h1"),
            .setMeta(TripMetaPatch(title: "New", subtitle: .some(nil))),
        ])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == #"[{"collection":"hotels","id":"h1","op":"delete"},{"meta":{"subtitle":null,"title":"New"},"op":"set_meta"}]"#)
    }

    @Test func roundTripsDocument() throws {
        let doc = try loadTrip().document
        let again = try SummaryJSON.decoder().decode(TripDocument.self, from: SummaryJSON.encoder().encode(doc))
        #expect(again == doc)
    }

    @Test func listQueryCarriesKind() {
        let items = SummaryListQuery(kind: .trip).queryItems
        #expect(items.contains(URLQueryItem(name: "kind", value: "trip")))
    }

    @Test func tripDeepLink() {
        let url = SummaryLink.openTripURL(tripID: "abc")
        #expect(url.absoluteString == "summarychip://trip/abc")
        #expect(SummaryLink.tripID(from: url) == "abc")
        #expect(SummaryLink.summaryID(from: url) == nil)
    }
}

@Suite struct TripQueryTests {
    @Test func dayForDateUsesTripTimeZone() throws {
        let doc = try loadTrip().document
        // 2026-10-10 20:00 UTC is already 2026-10-11 05:00 in Tokyo.
        let instant = try #require(SummaryJSON.parseISO8601("2026-10-10T20:00:00Z"))
        #expect(doc.day(for: instant)?.id == "d2")
        #expect(doc.contains(instant))
        let after = try #require(SummaryJSON.parseISO8601("2026-10-13T01:00:00Z"))
        #expect(doc.day(for: after) == nil)
        #expect(!doc.contains(after))
    }

    @Test func nearestDayPicksUpcomingVisit() throws {
        let doc = try loadTrip().document
        let nearSendai = CLLocationCoordinate2D(latitude: 38.25, longitude: 140.87)
        let before = try #require(SummaryJSON.parseISO8601("2026-10-01T00:00:00Z"))
        #expect(doc.nearestDay(to: nearSendai, today: before)?.id == "d2")
        let onThird = try #require(SummaryJSON.parseISO8601("2026-10-12T03:00:00Z"))
        #expect(doc.nearestDay(to: nearSendai, today: onThird)?.id == "d3")
        let osaka = CLLocationCoordinate2D(latitude: 34.69, longitude: 135.5)
        #expect(doc.nearestDay(to: osaka) == nil)
    }

    @Test func routeCoordinatesPreferDrawnPath() throws {
        let doc = try loadTrip().document
        #expect(doc.routeCoordinates(for: doc.days[1]).count == 3)
        #expect(doc.routeCoordinates(for: doc.days[0]).map(\.lat) == [35.772, 35.6812])
    }

    @Test func expenseTotalsSkipCoveredRows() throws {
        let doc = try loadTrip().document
        let totals = doc.expenseTotals()
        #expect(totals.map(\.currency) == ["JPY", "USD"])
        #expect(totals[0].amount == 34_200)
        #expect(totals[1].amount == 120)
        #expect(doc.expensesCovered(by: "e-pass").map(\.id) == ["e-shinkansen"])
    }

    @Test func removingRecordsClearsReferences() throws {
        var doc = try loadTrip().document
        doc.remove(.places, id: "tokyo")
        #expect(doc.days[1].route?.placeIds == ["sendai"])
        #expect(doc.hotels[0].placeId == nil)
        doc.remove(.transports, id: "t-hayabusa")
        #expect(doc.days[1].transportIds.isEmpty)
        #expect(doc.expense(id: "e-shinkansen")?.linkedId == nil)
        doc.remove(.expenses, id: "e-pass")
        #expect(doc.expense(id: "e-shinkansen")?.coveredByExpenseId == nil)
        doc.remove(.hotels, id: "h-tokyo")
        #expect(doc.days[0].stayId == nil)
    }

    @Test func upsertDayKeepsDateOrder() throws {
        var doc = try loadTrip().document
        doc.upsert(TripDay(id: "d0", date: "2026-10-09", title: "Pack"))
        #expect(doc.days.first?.id == "d0")
        #expect(doc.dayNumber(of: "d2") == 3)
    }

    @Test func picksCurrentThenUpcomingTrips() {
        let now = Date()
        let items = [
            TripListItem(id: "past", slug: "", title: "", startDate: "2026-01-01", endDate: "2026-01-05", updatedAt: now),
            TripListItem(id: "later", slug: "", title: "", startDate: "2026-12-01", endDate: "2026-12-05", updatedAt: now),
            TripListItem(id: "now", slug: "", title: "", startDate: "2026-10-01", endDate: "2026-10-09", updatedAt: now),
            TripListItem(id: "soon", slug: "", title: "", startDate: "2026-10-20", endDate: "2026-10-25", updatedAt: now),
        ]
        #expect(TripListItem.sortedForPicking(items, today: "2026-10-05").map(\.id) == ["now", "soon", "later", "past"])
    }

    @Test func listsTripDates() {
        #expect(TripDate.dates(from: "2026-12-30", through: "2027-01-02") == ["2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"])
        #expect(TripDate.daysBetween("2026-10-10", "2026-10-12") == 2)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let date = TripDate.localDateTime(from: "2026-10-11T09:36", timeZone: tokyo)!
        #expect(TripDate.localDateTimeString(from: date, timeZone: tokyo) == "2026-10-11T09:36")
    }
}

@Suite struct TripGeometryTests {
    @Test func samplesAlongRoute() throws {
        let route = TripRouteGeometry(points: [
            TripCoordinate(lat: 0, lng: 0), TripCoordinate(lat: 0, lng: 1), TripCoordinate(lat: 0, lng: 3),
        ])
        #expect(route.lengths.count == 3)
        #expect(abs(route.lengths[2] / route.lengths[1] - 3) < 1e-9)
        let start = try #require(route.sample(progress: 0))
        #expect(start.point == TripCoordinate(lat: 0, lng: 0))
        let half = try #require(route.sample(progress: 0.5))
        #expect(abs(half.point.lng - 1.5) < 1e-9)
        #expect(half.segment == 2)
        #expect(half.path.count == 3)
        let end = try #require(route.sample(progress: 2))
        #expect(end.point == TripCoordinate(lat: 0, lng: 3))
        #expect(end.path.count == 3)
        #expect(route.totalMeters > 300_000 && route.totalMeters < 340_000)
    }

    @Test func emptyRouteUsesFallback() {
        let empty = TripRouteGeometry(points: [])
        #expect(empty.sample(progress: 0.5) == nil)
        #expect(empty.sample(progress: 0.5, fallback: TripCoordinate(lat: 1, lng: 2))?.point == TripCoordinate(lat: 1, lng: 2))
    }

    @Test func readingLinePicksDayAndProgress() throws {
        let frames: [(minY: Double, maxY: Double)] = [(0, 380), (400, 780), (800, 1000)]
        #expect(TripReading.position(frames: frames, line: -10)?.index == 0)
        let mid = try #require(TripReading.position(frames: frames, line: 600))
        #expect(mid.index == 1)
        #expect(abs(mid.progress - 0.5) < 1e-9)
        let last = try #require(TripReading.position(frames: frames, line: 900))
        #expect(last.index == 2)
        #expect(abs(last.progress - 0.5) < 1e-9)
        #expect(TripReading.position(frames: [], line: 10) == nil)
    }
}

@Suite struct NorthboundFixtureTests {
    @Test func decodesServerFixture() throws {
        let doc = try SummaryJSON.decoder().decode(TripDocument.self, from: fixture("northbound-trip.json"))
        #expect(doc.timeZone == "Asia/Tokyo")
        #expect(doc.days.count == 11)
        #expect(!doc.places.isEmpty)
        // Every day with a route resolves to coordinates, and every reference points somewhere.
        for day in doc.days {
            if let route = day.route, route.kind != .stay {
                #expect(doc.routeCoordinates(for: day).count >= 1)
            }
            if let stay = day.stayId { #expect(doc.hotel(id: stay) != nil) }
            for id in day.transportIds { #expect(doc.transport(id: id) != nil) }
        }
        let first = try #require(SummaryJSON.parseISO8601("2026-10-10T03:00:00Z"))
        #expect(doc.day(for: first)?.date == "2026-10-10")
        let again = try SummaryJSON.decoder().decode(TripDocument.self, from: SummaryJSON.encoder().encode(doc))
        #expect(again == doc)
    }
}

@Suite struct TripViewTests {
    private func northbound() throws -> TripDocument {
        try SummaryJSON.decoder().decode(TripDocument.self, from: fixture("northbound-trip.json"))
    }

    @Test func decodesPassVsICView() throws {
        let doc = try northbound()
        let view = try #require(doc.view(id: "view-jr-pass-vs-ic"))
        #expect(doc.views(forDay: nil).map(\.id) == ["view-jr-pass-vs-ic"])
        #expect(doc.views(forDay: "day-5").map(\.id) == ["view-pass-day-1"])
        #expect(view.spec.elements[view.spec.root]?.type == "Stack")
        #expect(view.spec.elements["stat-ic"]?.number("value") == 48440)

        let table = TripViewTable(try #require(view.spec.elements["table"]))
        #expect(table.columns.map(\.key) == ["date", "route", "ic", "pass"])
        #expect(table.total(of: table.columns[2]) == 48440)
        #expect(table.total(of: table.columns[3]) == 53020)
        #expect(table.total(of: table.columns[0]) == nil)
    }

    @Test func encodesLeavesWithoutChildren() throws {
        let view = TripView(id: "v", title: "V", spec: TripViewSpec(root: "t", elements: ["t": TripViewElement(type: "Text", props: ["text": .string("Hi")])]))
        let data = try SummaryJSON.encoder().encode(TripOperation.upsertView(view))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == #"{"op":"upsert_view","view":{"id":"v","spec":{"elements":{"t":{"props":{"text":"Hi"},"type":"Text"}},"root":"t"},"title":"V"}}"#)
    }

    @Test func deletingDayMovesItsViewsToTheTrip() throws {
        var doc = try northbound()
        doc.remove(.days, id: "day-5")
        #expect(doc.view(id: "view-pass-day-1")?.dayId == nil)
        doc.remove(.views, id: "view-pass-day-1")
        #expect(doc.view(id: "view-pass-day-1") == nil)
    }

    @Test func formatsValues() {
        #expect(TripViewFormat.text(.string("Included"), format: "money", currency: nil, defaultCurrency: "JPY") == "Included")
        #expect(TripViewFormat.text(nil, format: nil, currency: nil, defaultCurrency: "JPY") == "—")
        #expect(TripViewFormat.text(.number(1500), format: "money", currency: nil, defaultCurrency: "JPY").contains("1,500"))
    }
}

