import CoreLocation
import Foundation

// Swift mirror of the trip diary document (v1) in `server/lib/contracts/trip.ts`.
// Dates stay `YYYY-MM-DD` strings and times `YYYY-MM-DDTHH:mm` strings, local to the trip's
// `timeZone`; `TripDate` converts them. Decoding is lenient: unknown enum values fall back to the
// contract's default, and defaulted arrays and flags may be absent.

/// A contract enum that decodes unknown values as `fallback` instead of failing the whole trip.
public protocol TripLenientEnum: RawRepresentable, Codable, CaseIterable, Sendable, Hashable, Identifiable where RawValue == String {
    static var fallback: Self { get }
}

public extension TripLenientEnum {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .fallback
    }

    var id: String { rawValue }
}

public enum TripPlaceKind: String, TripLenientEnum {
    case city, station, airport, hotel, poi, port
    public static let fallback: Self = .poi
}

public enum TripRouteKind: String, TripLenientEnum {
    case out, side, back, ferry, airport, stay
    public static let fallback: Self = .out
}

public enum TripMomentSlot: String, TripLenientEnum {
    case morning, afternoon, evening, night
    public static let fallback: Self = .morning
}

public enum TripBookingStatus: String, TripLenientEnum {
    case idea, planned, booked
    public static let fallback: Self = .planned
}

public enum TripSegmentMode: String, TripLenientEnum {
    case train, flight, ferry, bus, car, walk, other
    public static let fallback: Self = .other
}

public enum TripTrainCategory: String, TripLenientEnum {
    case shinkansen
    case limitedExpress = "limited_express"
    case rapid, local, other
    public static let fallback: Self = .other
}

/// Optional in the contract, so an unknown value decodes as `nil` (see `decodeLenientSeatClass`).
public enum TripSeatClass: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case reserved
    case nonReserved = "non_reserved"
    case green
    case granClass = "gran_class"
    case economy
    case premiumEconomy = "premium_economy"
    case business, first

    public var id: String { rawValue }
}

public enum TripExpenseCategory: String, TripLenientEnum {
    case transport, lodging, food, activity, shopping, pass, other
    public static let fallback: Self = .other
}

/// The document arrays records live in; the `collection` of a `delete` operation.
public enum TripCollection: String, Codable, CaseIterable, Sendable, Hashable {
    case places, days, transports, hotels, expenses, notes, views, plans
}

public enum TripPlanScope: String, TripLenientEnum {
    case trip, day
    public static let fallback: TripPlanScope = .trip
}

public struct TripCoordinate: Codable, Sendable, Hashable {
    public var lat: Double
    public var lng: Double

    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }

    public init(_ coordinate: CLLocationCoordinate2D) {
        self.init(lat: coordinate.latitude, lng: coordinate.longitude)
    }

    public var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }

    /// Great-circle distance in metres.
    public func distance(to other: TripCoordinate) -> CLLocationDistance {
        CLLocation(latitude: lat, longitude: lng).distance(from: CLLocation(latitude: other.lat, longitude: other.lng))
    }
}

public struct TripMoney: Codable, Sendable, Hashable {
    public var amount: Double
    /// ISO 4217, e.g. `JPY`.
    public var currency: String

    public init(amount: Double, currency: String) {
        self.amount = amount
        self.currency = currency
    }

    public var formatted: String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(0...2)))
    }
}

/// A photo of a place: a direct https image URL, what it shows and who took it.
public struct TripPhoto: Codable, Sendable, Hashable {
    public var url: String
    public var caption: String?
    /// Attribution shown under the photo ("Photo: Wikimedia Commons / Jane Doe").
    public var credit: String?
    /// The page the photo came from.
    public var sourceUrl: String?

    public init(url: String, caption: String? = nil, credit: String? = nil, sourceUrl: String? = nil) {
        self.url = url; self.caption = caption; self.credit = credit; self.sourceUrl = sourceUrl
    }

    /// Only https images load (the server refuses anything else).
    public var imageURL: URL? {
        guard let url = URL(string: url), url.scheme == "https" else { return nil }
        return url
    }
}

/// One line of a place's price list: an admission tier, a set menu. No price means free.
public struct TripPriceItem: Codable, Sendable, Hashable {
    public var label: String
    public var price: TripMoney?
    public var note: String?

    public init(label: String, price: TripMoney? = nil, note: String? = nil) {
        self.label = label; self.price = price; self.note = note
    }
}

public struct TripPlace: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: TripPlaceKind
    public var coordinate: TripCoordinate
    public var address: String?
    public var note: String?
    /// Major places keep their label on the map.
    public var major: Bool
    /// What the place is and why it's worth the visit, like a guidebook entry.
    public var description: String?
    public var photos: [TripPhoto]
    /// Opening hours as written ("9:00–17:00, closed Mondays").
    public var hours: String?
    /// How long a visit takes ("1–2 h").
    public var visitDuration: String?
    public var pricing: [TripPriceItem]
    public var website: String?
    public var phone: String?

    public init(
        id: String, name: String, kind: TripPlaceKind = .poi, coordinate: TripCoordinate, address: String? = nil,
        note: String? = nil, major: Bool = false, description: String? = nil, photos: [TripPhoto] = [],
        hours: String? = nil, visitDuration: String? = nil, pricing: [TripPriceItem] = [], website: String? = nil, phone: String? = nil
    ) {
        self.id = id; self.name = name; self.kind = kind; self.coordinate = coordinate
        self.address = address; self.note = note; self.major = major; self.description = description
        self.photos = photos; self.hours = hours; self.visitDuration = visitDuration; self.pricing = pricing
        self.website = website; self.phone = phone
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(TripPlaceKind.self, forKey: .kind) ?? .poi
        coordinate = try c.decode(TripCoordinate.self, forKey: .coordinate)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        major = try c.decodeIfPresent(Bool.self, forKey: .major) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description)
        photos = try c.decodeIfPresent([TripPhoto].self, forKey: .photos) ?? []
        hours = try c.decodeIfPresent(String.self, forKey: .hours)
        visitDuration = try c.decodeIfPresent(String.self, forKey: .visitDuration)
        pricing = try c.decodeIfPresent([TripPriceItem].self, forKey: .pricing) ?? []
        website = try c.decodeIfPresent(String.self, forKey: .website)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
    }

    /// Whether there's more to show than the pin: photos, a description, hours, prices or contacts.
    public var hasDetails: Bool {
        !photos.isEmpty || !pricing.isEmpty || [description, hours, visitDuration, website, phone, note].contains { $0?.isEmpty == false }
    }
}

public struct TripDayRoute: Codable, Sendable, Hashable {
    public var kind: TripRouteKind
    public var placeIds: [String]
    /// Optional drawn path; when absent the places are connected in order.
    public var path: [TripCoordinate]?
    public var summary: String?

    public init(kind: TripRouteKind, placeIds: [String] = [], path: [TripCoordinate]? = nil, summary: String? = nil) {
        self.kind = kind; self.placeIds = placeIds; self.path = path; self.summary = summary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(TripRouteKind.self, forKey: .kind)
        placeIds = try c.decodeIfPresent([String].self, forKey: .placeIds) ?? []
        path = try c.decodeIfPresent([TripCoordinate].self, forKey: .path)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}

public struct TripMoment: Codable, Sendable, Hashable {
    public var slot: TripMomentSlot
    /// `HH:mm`.
    public var time: String?
    public var text: String
    public var placeId: String?

    public init(slot: TripMomentSlot, time: String? = nil, text: String, placeId: String? = nil) {
        self.slot = slot; self.time = time; self.text = text; self.placeId = placeId
    }
}

public struct TripDay: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `YYYY-MM-DD`.
    public var date: String
    public var title: String
    public var short: String?
    public var blurb: String?
    public var highlight: Bool
    public var route: TripDayRoute?
    public var moments: [TripMoment]
    public var tip: String?
    /// The hotel slept in that night.
    public var stayId: String?
    public var transportIds: [String]
    /// The plan option this day is part of; nil when every option shares it.
    public var planOptionId: String?

    public init(
        id: String, date: String, title: String, short: String? = nil, blurb: String? = nil, highlight: Bool = false,
        route: TripDayRoute? = nil, moments: [TripMoment] = [], tip: String? = nil, stayId: String? = nil, transportIds: [String] = [],
        planOptionId: String? = nil
    ) {
        self.id = id; self.date = date; self.title = title; self.short = short; self.blurb = blurb
        self.highlight = highlight; self.route = route; self.moments = moments; self.tip = tip
        self.stayId = stayId; self.transportIds = transportIds; self.planOptionId = planOptionId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        title = try c.decode(String.self, forKey: .title)
        short = try c.decodeIfPresent(String.self, forKey: .short)
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb)
        highlight = try c.decodeIfPresent(Bool.self, forKey: .highlight) ?? false
        route = try c.decodeIfPresent(TripDayRoute.self, forKey: .route)
        moments = try c.decodeIfPresent([TripMoment].self, forKey: .moments) ?? []
        tip = try c.decodeIfPresent(String.self, forKey: .tip)
        stayId = try c.decodeIfPresent(String.self, forKey: .stayId)
        transportIds = try c.decodeIfPresent([String].self, forKey: .transportIds) ?? []
        planOptionId = try c.decodeIfPresent(String.self, forKey: .planOptionId)
    }
}

public struct TripTrainDetails: Codable, Sendable, Hashable {
    public var `operator`: String?
    public var line: String?
    public var name: String?
    public var number: String?
    public var category: TripTrainCategory
    public var carNumber: String?
    public var seat: String?
    public var seatClass: TripSeatClass?

    public init(
        operator: String? = nil, line: String? = nil, name: String? = nil, number: String? = nil, category: TripTrainCategory = .other,
        carNumber: String? = nil, seat: String? = nil, seatClass: TripSeatClass? = nil
    ) {
        self.operator = `operator`; self.line = line; self.name = name; self.number = number
        self.category = category; self.carNumber = carNumber; self.seat = seat; self.seatClass = seatClass
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `operator` = try c.decodeIfPresent(String.self, forKey: .operator)
        line = try c.decodeIfPresent(String.self, forKey: .line)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        number = try c.decodeIfPresent(String.self, forKey: .number)
        category = try c.decodeIfPresent(TripTrainCategory.self, forKey: .category) ?? .other
        carNumber = try c.decodeIfPresent(String.self, forKey: .carNumber)
        seat = try c.decodeIfPresent(String.self, forKey: .seat)
        seatClass = c.decodeLenientSeatClass(forKey: .seatClass)
    }
}

public struct TripFlightDetails: Codable, Sendable, Hashable {
    public var airline: String?
    public var flightNumber: String
    public var fromIATA: String?
    public var toIATA: String?
    public var terminal: String?
    public var gate: String?
    public var seat: String?
    public var seatClass: TripSeatClass?
    public var bookingRef: String?

    public init(
        airline: String? = nil, flightNumber: String, fromIATA: String? = nil, toIATA: String? = nil, terminal: String? = nil,
        gate: String? = nil, seat: String? = nil, seatClass: TripSeatClass? = nil, bookingRef: String? = nil
    ) {
        self.airline = airline; self.flightNumber = flightNumber; self.fromIATA = fromIATA; self.toIATA = toIATA
        self.terminal = terminal; self.gate = gate; self.seat = seat; self.seatClass = seatClass; self.bookingRef = bookingRef
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        airline = try c.decodeIfPresent(String.self, forKey: .airline)
        flightNumber = try c.decode(String.self, forKey: .flightNumber)
        fromIATA = try c.decodeIfPresent(String.self, forKey: .fromIATA)
        toIATA = try c.decodeIfPresent(String.self, forKey: .toIATA)
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal)
        gate = try c.decodeIfPresent(String.self, forKey: .gate)
        seat = try c.decodeIfPresent(String.self, forKey: .seat)
        seatClass = c.decodeLenientSeatClass(forKey: .seatClass)
        bookingRef = try c.decodeIfPresent(String.self, forKey: .bookingRef)
    }
}

public struct TripSegment: Codable, Sendable, Hashable {
    public var mode: TripSegmentMode
    public var fromPlaceId: String?
    public var toPlaceId: String?
    public var fromName: String
    public var toName: String
    /// `YYYY-MM-DDTHH:mm`, local.
    public var departure: String?
    public var arrival: String?
    public var train: TripTrainDetails?
    public var flight: TripFlightDetails?
    public var price: TripMoney?
    public var sourceUrl: String?

    public init(
        mode: TripSegmentMode, fromPlaceId: String? = nil, toPlaceId: String? = nil, fromName: String, toName: String,
        departure: String? = nil, arrival: String? = nil, train: TripTrainDetails? = nil, flight: TripFlightDetails? = nil,
        price: TripMoney? = nil, sourceUrl: String? = nil
    ) {
        self.mode = mode; self.fromPlaceId = fromPlaceId; self.toPlaceId = toPlaceId; self.fromName = fromName
        self.toName = toName; self.departure = departure; self.arrival = arrival; self.train = train
        self.flight = flight; self.price = price; self.sourceUrl = sourceUrl
    }
}

public struct TripTransportOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var departure: String?
    public var arrival: String?
    public var duration: String?
    public var fare: TripMoney?
    public var warning: String?
    public var notes: [String]
    public var segments: [TripSegment]

    public init(
        id: String, label: String, departure: String? = nil, arrival: String? = nil, duration: String? = nil,
        fare: TripMoney? = nil, warning: String? = nil, notes: [String] = [], segments: [TripSegment] = []
    ) {
        self.id = id; self.label = label; self.departure = departure; self.arrival = arrival; self.duration = duration
        self.fare = fare; self.warning = warning; self.notes = notes; self.segments = segments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        departure = try c.decodeIfPresent(String.self, forKey: .departure)
        arrival = try c.decodeIfPresent(String.self, forKey: .arrival)
        duration = try c.decodeIfPresent(String.self, forKey: .duration)
        fare = try c.decodeIfPresent(TripMoney.self, forKey: .fare)
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        segments = try c.decodeIfPresent([TripSegment].self, forKey: .segments) ?? []
    }

    /// The option's departure, else its first segment's.
    public var effectiveDeparture: String? { departure ?? segments.first?.departure }
    /// The option's arrival, else its last segment's.
    public var effectiveArrival: String? { arrival ?? segments.last?.arrival }
}

public struct TripTransport: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var date: String
    public var label: String
    public var status: TripBookingStatus
    public var selectedOptionId: String?
    /// At least one.
    public var options: [TripTransportOption]
    /// The plan option this transport is part of; nil when every option shares it.
    public var planOptionId: String?

    public init(
        id: String, date: String, label: String, status: TripBookingStatus = .planned, selectedOptionId: String? = nil,
        options: [TripTransportOption], planOptionId: String? = nil
    ) {
        self.id = id; self.date = date; self.label = label; self.status = status
        self.selectedOptionId = selectedOptionId; self.options = options; self.planOptionId = planOptionId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        label = try c.decode(String.self, forKey: .label)
        status = try c.decodeIfPresent(TripBookingStatus.self, forKey: .status) ?? .planned
        selectedOptionId = try c.decodeIfPresent(String.self, forKey: .selectedOptionId)
        options = try c.decodeIfPresent([TripTransportOption].self, forKey: .options) ?? []
        planOptionId = try c.decodeIfPresent(String.self, forKey: .planOptionId)
    }

    /// The chosen option, else the first one.
    public var selectedOption: TripTransportOption? {
        options.first { $0.id == selectedOptionId } ?? options.first
    }
}

public struct TripHotel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var placeId: String?
    public var address: String?
    public var checkIn: String
    public var checkOut: String
    /// `HH:mm`.
    public var checkInTime: String?
    public var confirmation: String?
    public var price: TripMoney?
    public var url: String?
    public var status: TripBookingStatus
    /// The plan option this stay is part of; nil when every option shares it.
    public var planOptionId: String?

    public init(
        id: String, name: String, placeId: String? = nil, address: String? = nil, checkIn: String, checkOut: String,
        checkInTime: String? = nil, confirmation: String? = nil, price: TripMoney? = nil, url: String? = nil, status: TripBookingStatus = .planned,
        planOptionId: String? = nil
    ) {
        self.id = id; self.name = name; self.placeId = placeId; self.address = address; self.checkIn = checkIn
        self.checkOut = checkOut; self.checkInTime = checkInTime; self.confirmation = confirmation
        self.price = price; self.url = url; self.status = status; self.planOptionId = planOptionId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        placeId = try c.decodeIfPresent(String.self, forKey: .placeId)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        checkIn = try c.decode(String.self, forKey: .checkIn)
        checkOut = try c.decode(String.self, forKey: .checkOut)
        checkInTime = try c.decodeIfPresent(String.self, forKey: .checkInTime)
        confirmation = try c.decodeIfPresent(String.self, forKey: .confirmation)
        price = try c.decodeIfPresent(TripMoney.self, forKey: .price)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        status = try c.decodeIfPresent(TripBookingStatus.self, forKey: .status) ?? .planned
        planOptionId = try c.decodeIfPresent(String.self, forKey: .planOptionId)
    }
}

public struct TripExpense: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var date: String?
    public var dayId: String?
    public var category: TripExpenseCategory
    public var title: String
    public var amount: TripMoney
    public var paid: Bool
    /// The pass/bundle expense that covers this one (e.g. a JR pass). Covered rows don't add to totals.
    public var coveredByExpenseId: String?
    /// The transport or hotel this cost belongs to.
    public var linkedId: String?
    /// The plan option this cost is part of; nil when every option shares it.
    public var planOptionId: String?

    public init(
        id: String, date: String? = nil, dayId: String? = nil, category: TripExpenseCategory, title: String, amount: TripMoney,
        paid: Bool = false, coveredByExpenseId: String? = nil, linkedId: String? = nil, planOptionId: String? = nil
    ) {
        self.id = id; self.date = date; self.dayId = dayId; self.category = category; self.title = title
        self.amount = amount; self.paid = paid; self.coveredByExpenseId = coveredByExpenseId; self.linkedId = linkedId
        self.planOptionId = planOptionId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        dayId = try c.decodeIfPresent(String.self, forKey: .dayId)
        category = try c.decodeIfPresent(TripExpenseCategory.self, forKey: .category) ?? .other
        title = try c.decode(String.self, forKey: .title)
        amount = try c.decode(TripMoney.self, forKey: .amount)
        paid = try c.decodeIfPresent(Bool.self, forKey: .paid) ?? false
        coveredByExpenseId = try c.decodeIfPresent(String.self, forKey: .coveredByExpenseId)
        linkedId = try c.decodeIfPresent(String.self, forKey: .linkedId)
        planOptionId = try c.decodeIfPresent(String.self, forKey: .planOptionId)
    }

    public var isCovered: Bool { coveredByExpenseId != nil }
}

public struct TripNote: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var text: String
    /// The plan option this note is part of; nil when every option shares it.
    public var planOptionId: String?

    public init(id: String, title: String, text: String, planOptionId: String? = nil) {
        self.id = id; self.title = title; self.text = text; self.planOptionId = planOptionId
    }
}

public struct TripSource: Codable, Sendable, Hashable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// One element of a custom view: a catalog component (`Stack`, `Table`, `Stat`…), its props and,
/// for containers, the ids of its children. Props stay raw JSON so a view round-trips unchanged
/// and components the app doesn't know yet are skipped rather than failing the trip.
public struct TripViewElement: Codable, Sendable, Hashable {
    public var type: String
    public var props: [String: JSONValue]
    public var children: [String]

    public init(type: String, props: [String: JSONValue] = [:], children: [String] = []) {
        self.type = type; self.props = props; self.children = children
    }

    private enum CodingKeys: String, CodingKey { case type, props, children }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        props = try c.decodeIfPresent([String: JSONValue].self, forKey: .props) ?? [:]
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(props, forKey: .props)
        // Leaves refuse a `children` key on the server.
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }
}

/// A json-render style spec: a flat map of elements and the id of the root.
public struct TripViewSpec: Codable, Sendable, Hashable {
    public var root: String
    public var elements: [String: TripViewElement]

    public init(root: String, elements: [String: TripViewElement]) {
        self.root = root
        self.elements = elements
    }
}

/// A custom view (a comparison table, a budget…). With `dayId` it shows inside that day, else in
/// the trip's Views section. Spec: `server/lib/contracts/trip-view.ts`.
public struct TripView: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var dayId: String?
    public var spec: TripViewSpec
    /// The plan option this view is part of; nil when every option shares it.
    public var planOptionId: String?

    public init(id: String, title: String, dayId: String? = nil, spec: TripViewSpec, planOptionId: String? = nil) {
        self.id = id; self.title = title; self.dayId = dayId; self.spec = spec; self.planOptionId = planOptionId
    }
}

/// One alternative of a plan: "Route 1 · Coast".
public struct TripPlanOption: Codable, Sendable, Hashable, Identifiable {
    /// Unique across all of the trip's plans; records point at it with `planOptionId`.
    public var id: String
    public var label: String
    /// What sets this option apart.
    public var summary: String?

    public init(id: String, label: String, summary: String? = nil) {
        self.id = id; self.label = label; self.summary = summary
    }
}

/// A choice between alternative plans for the whole trip or one day. Records tagged with an
/// option's id only show while that option is picked; each reader's pick is saved for them.
public struct TripPlan: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var scope: TripPlanScope
    /// The day a `day` plan decides, `YYYY-MM-DD`.
    public var date: String?
    /// Two to six.
    public var options: [TripPlanOption]
    public var defaultOptionId: String?

    public init(id: String, title: String, scope: TripPlanScope = .trip, date: String? = nil, options: [TripPlanOption], defaultOptionId: String? = nil) {
        self.id = id; self.title = title; self.scope = scope; self.date = date; self.options = options; self.defaultOptionId = defaultOptionId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        scope = try c.decodeIfPresent(TripPlanScope.self, forKey: .scope) ?? .trip
        date = try c.decodeIfPresent(String.self, forKey: .date)
        options = try c.decodeIfPresent([TripPlanOption].self, forKey: .options) ?? []
        defaultOptionId = try c.decodeIfPresent(String.self, forKey: .defaultOptionId)
    }

    /// The option a reader follows: their pick while it exists, else the default, else the first.
    public func selectedOptionID(in selections: [String: String]) -> String? {
        if let picked = selections[id], options.contains(where: { $0.id == picked }) { return picked }
        if let defaultOptionId, options.contains(where: { $0.id == defaultOptionId }) { return defaultOptionId }
        return options.first?.id
    }
}

/// The whole trip diary: meta plus records that reference each other by id.
public struct TripDocument: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var title: String
    public var subtitle: String?
    public var intro: String?
    public var startDate: String
    public var endDate: String
    /// IANA identifier; dates and local times in the document are in this zone.
    public var timeZone: String
    /// ISO 4217 default currency for new costs.
    public var currency: String
    public var places: [TripPlace]
    public var days: [TripDay]
    public var transports: [TripTransport]
    public var hotels: [TripHotel]
    public var expenses: [TripExpense]
    public var notes: [TripNote]
    public var sources: [TripSource]
    public var views: [TripView]
    /// Alternative plans (route 1 / route 2…) for the trip or a day.
    public var plans: [TripPlan]

    public init(
        title: String, subtitle: String? = nil, intro: String? = nil, startDate: String, endDate: String,
        timeZone: String = "UTC", currency: String = "USD", places: [TripPlace] = [], days: [TripDay] = [],
        transports: [TripTransport] = [], hotels: [TripHotel] = [], expenses: [TripExpense] = [],
        notes: [TripNote] = [], sources: [TripSource] = [], views: [TripView] = [], plans: [TripPlan] = []
    ) {
        self.version = Self.currentVersion
        self.title = title; self.subtitle = subtitle; self.intro = intro; self.startDate = startDate
        self.endDate = endDate; self.timeZone = timeZone; self.currency = currency; self.places = places
        self.days = days; self.transports = transports; self.hotels = hotels; self.expenses = expenses
        self.notes = notes; self.sources = sources; self.views = views; self.plans = plans
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        startDate = try c.decode(String.self, forKey: .startDate)
        endDate = try c.decode(String.self, forKey: .endDate)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? "UTC"
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        places = try c.decodeIfPresent([TripPlace].self, forKey: .places) ?? []
        days = try c.decodeIfPresent([TripDay].self, forKey: .days) ?? []
        transports = try c.decodeIfPresent([TripTransport].self, forKey: .transports) ?? []
        hotels = try c.decodeIfPresent([TripHotel].self, forKey: .hotels) ?? []
        expenses = try c.decodeIfPresent([TripExpense].self, forKey: .expenses) ?? []
        notes = try c.decodeIfPresent([TripNote].self, forKey: .notes) ?? []
        sources = try c.decodeIfPresent([TripSource].self, forKey: .sources) ?? []
        views = try c.decodeIfPresent([TripView].self, forKey: .views) ?? []
        plans = try c.decodeIfPresent([TripPlan].self, forKey: .plans) ?? []
    }
}

/// `GET /api/v1/trips/:id`: a trip document with its library row. `id` is the summary id.
public struct Trip: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    /// Bumped on every save; send it back with `PUT` so concurrent edits are detected.
    public var revision: Int
    public var visibility: SummaryVisibility
    public var createdAt: Date
    public var updatedAt: Date
    public var shareUrl: URL?
    /// Only the owner can edit; others see the diary read-only.
    public var isOwner: Bool
    public var document: TripDocument
    /// When the user starred the trip; only `GET /api/v1/trips/:id` sends it, saves leave it nil.
    public var likedAt: Date?
    /// The language `document`'s texts are in: a translation's, else `originalLanguage`.
    public var language: String
    /// The language the trip is written in.
    public var originalLanguage: String
    /// Owner only: the language they chose to read it in (`PATCH displayLanguage`); nil = as written.
    public var displayLanguage: String?
    /// A background run is translating the trip into the language being read: the texts not
    /// translated yet show as written, and the owner gets a push when it's done.
    public var translating: Bool
    /// The plan options the user last picked (plan id → option id); only reads send it.
    public var planSelections: [String: String]?

    public init(
        id: String, slug: String, revision: Int, visibility: SummaryVisibility = .private, createdAt: Date, updatedAt: Date, shareUrl: URL?,
        isOwner: Bool = true, document: TripDocument, likedAt: Date? = nil,
        language: String = "en", originalLanguage: String? = nil, displayLanguage: String? = nil, translating: Bool = false,
        planSelections: [String: String]? = nil
    ) {
        self.id = id; self.slug = slug; self.revision = revision; self.visibility = visibility; self.isOwner = isOwner; self.likedAt = likedAt
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.shareUrl = shareUrl; self.document = document
        self.language = language; self.originalLanguage = originalLanguage ?? language; self.displayLanguage = displayLanguage
        self.translating = translating
        self.planSelections = planSelections
    }

    /// The diary is shown translated from `originalLanguage`. Translations are read-only: edits are
    /// made to the trip as written.
    public var isTranslated: Bool { language != originalLanguage }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        visibility = try c.decodeIfPresent(SummaryVisibility.self, forKey: .visibility) ?? .private
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        shareUrl = try c.decodeLenientURL(forKey: .shareUrl)
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? true
        document = try c.decode(TripDocument.self, forKey: .document)
        likedAt = try c.decodeIfPresent(Date.self, forKey: .likedAt)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        originalLanguage = try c.decodeIfPresent(String.self, forKey: .originalLanguage) ?? language
        displayLanguage = try c.decodeIfPresent(String.self, forKey: .displayLanguage)
        translating = try c.decodeIfPresent(Bool.self, forKey: .translating) ?? false
        planSelections = try c.decodeIfPresent([String: String].self, forKey: .planSelections)
    }
}

/// One row of `GET /api/v1/trips`.
public struct TripListItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    public var title: String
    public var subtitle: String?
    public var startDate: String
    public var endDate: String
    public var revision: Int
    public var updatedAt: Date
    public var dayCount: Int
    public var placeCount: Int

    public init(id: String, slug: String, title: String, subtitle: String? = nil, startDate: String, endDate: String, revision: Int = 0, updatedAt: Date, dayCount: Int = 0, placeCount: Int = 0) {
        self.id = id; self.slug = slug; self.title = title; self.subtitle = subtitle; self.startDate = startDate
        self.endDate = endDate; self.revision = revision; self.updatedAt = updatedAt; self.dayCount = dayCount; self.placeCount = placeCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        startDate = try c.decode(String.self, forKey: .startDate)
        endDate = try c.decode(String.self, forKey: .endDate)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        dayCount = try c.decodeIfPresent(Int.self, forKey: .dayCount) ?? 0
        placeCount = try c.decodeIfPresent(Int.self, forKey: .placeCount) ?? 0
    }

    /// Trips under way first, then upcoming ones soonest first, then past ones most recent first.
    /// `today` is `YYYY-MM-DD`.
    public static func sortedForPicking(_ items: [TripListItem], today: String) -> [TripListItem] {
        func rank(_ item: TripListItem) -> Int {
            if item.startDate <= today && today <= item.endDate { return 0 }
            return item.startDate > today ? 1 : 2
        }
        return items.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return ra == 2 ? a.endDate > b.endDate : a.startDate < b.startDate
        }
    }
}

/// `set_meta`: only the fields given change. `subtitle`/`intro` set to `.some(nil)` clear them.
public struct TripMetaPatch: Encodable, Sendable, Hashable {
    public var title: String?
    public var subtitle: String??
    public var intro: String??
    public var startDate: String?
    public var endDate: String?
    public var timeZone: String?
    public var currency: String?

    public init(title: String? = nil, subtitle: String?? = nil, intro: String?? = nil, startDate: String? = nil, endDate: String? = nil, timeZone: String? = nil, currency: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.intro = intro; self.startDate = startDate
        self.endDate = endDate; self.timeZone = timeZone; self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case title, subtitle, intro, startDate, endDate, timeZone, currency }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        if let subtitle {
            if let subtitle { try c.encode(subtitle, forKey: .subtitle) } else { try c.encodeNil(forKey: .subtitle) }
        }
        if let intro {
            if let intro { try c.encode(intro, forKey: .intro) } else { try c.encodeNil(forKey: .intro) }
        }
        try c.encodeIfPresent(startDate, forKey: .startDate)
        try c.encodeIfPresent(endDate, forKey: .endDate)
        try c.encodeIfPresent(timeZone, forKey: .timeZone)
        try c.encodeIfPresent(currency, forKey: .currency)
    }
}

/// One entity-level edit for `POST /api/v1/trips/:id/operations`, discriminated by `op`.
public enum TripOperation: Encodable, Sendable, Hashable {
    case setMeta(TripMetaPatch)
    case upsertPlace(TripPlace)
    case upsertDay(TripDay)
    case upsertTransport(TripTransport)
    case upsertHotel(TripHotel)
    case upsertExpense(TripExpense)
    case upsertNote(TripNote)
    case upsertView(TripView)
    case upsertPlan(TripPlan)
    /// Settles a plan on one option: its records stay, the other options' records and the plan go.
    case resolvePlan(id: String, optionId: String)
    case addSource(TripSource)
    case delete(TripCollection, id: String)

    private enum CodingKeys: String, CodingKey { case op, meta, place, day, transport, hotel, expense, note, view, plan, source, collection, id, optionId }

    public var op: String {
        switch self {
        case .setMeta: "set_meta"
        case .upsertPlace: "upsert_place"
        case .upsertDay: "upsert_day"
        case .upsertTransport: "upsert_transport"
        case .upsertHotel: "upsert_hotel"
        case .upsertExpense: "upsert_expense"
        case .upsertNote: "upsert_note"
        case .upsertView: "upsert_view"
        case .upsertPlan: "upsert_plan"
        case .resolvePlan: "resolve_plan"
        case .addSource: "add_source"
        case .delete: "delete"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        switch self {
        case .setMeta(let meta): try c.encode(meta, forKey: .meta)
        case .upsertPlace(let place): try c.encode(place, forKey: .place)
        case .upsertDay(let day): try c.encode(day, forKey: .day)
        case .upsertTransport(let transport): try c.encode(transport, forKey: .transport)
        case .upsertHotel(let hotel): try c.encode(hotel, forKey: .hotel)
        case .upsertExpense(let expense): try c.encode(expense, forKey: .expense)
        case .upsertNote(let note): try c.encode(note, forKey: .note)
        case .upsertView(let view): try c.encode(view, forKey: .view)
        case .upsertPlan(let plan): try c.encode(plan, forKey: .plan)
        case .resolvePlan(let id, let optionId):
            try c.encode(id, forKey: .id)
            try c.encode(optionId, forKey: .optionId)
        case .addSource(let source): try c.encode(source, forKey: .source)
        case .delete(let collection, let id):
            try c.encode(collection, forKey: .collection)
            try c.encode(id, forKey: .id)
        }
    }
}

// MARK: - Dates

/// Converts the document's `YYYY-MM-DD` dates and `YYYY-MM-DDTHH:mm` local times, always in the
/// trip's time zone and the Gregorian calendar.
public enum TripDate {
    public static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Midnight of a `YYYY-MM-DD` date in `timeZone`.
    public static func date(from value: String, timeZone: TimeZone) -> Date? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar(timeZone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The `YYYY-MM-DD` day `date` falls on in `timeZone`.
    public static func string(from date: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A `YYYY-MM-DDTHH:mm` wall-clock time in `timeZone`.
    public static func localDateTime(from value: String, timeZone: TimeZone) -> Date? {
        guard value.count >= 16, let day = date(from: value, timeZone: timeZone),
              let hour = Int(value.dropFirst(11).prefix(2)), let minute = Int(value.dropFirst(14).prefix(2)) else { return nil }
        return calendar(timeZone).date(byAdding: DateComponents(hour: hour, minute: minute), to: day)
    }

    public static func localDateTimeString(from date: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// `HH:mm` of a local time in `timeZone`.
    public static func clockString(from date: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// `"05:53"` from `"2026-10-12T05:53"`; nil when not a local time.
    public static func clock(_ localDateTime: String?) -> String? {
        guard let localDateTime, localDateTime.count >= 16 else { return nil }
        return String(localDateTime.dropFirst(11).prefix(5))
    }

    /// Every `YYYY-MM-DD` from `start` through `end`, inclusive.
    public static func dates(from start: String, through end: String) -> [String] {
        let utc = TimeZone(identifier: "UTC") ?? .current
        guard var day = date(from: start, timeZone: utc), let last = date(from: end, timeZone: utc), day <= last else { return [] }
        var result: [String] = []
        let calendar = calendar(utc)
        while day <= last, result.count < 366 {
            result.append(string(from: day, timeZone: utc))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Days from `start` to `end` (`YYYY-MM-DD`), e.g. 0 for the same day.
    public static func daysBetween(_ start: String, _ end: String) -> Int? {
        let utc = TimeZone(identifier: "UTC") ?? .current
        guard let a = date(from: start, timeZone: utc), let b = date(from: end, timeZone: utc) else { return nil }
        return calendar(utc).dateComponents([.day], from: a, to: b).day
    }
}

// MARK: - Queries

public struct TripCurrencyTotal: Sendable, Hashable, Identifiable {
    public var currency: String
    public var amount: Double
    public var id: String { currency }

    public var money: TripMoney { TripMoney(amount: amount, currency: currency) }
}

public extension TripDocument {
    var resolvedTimeZone: TimeZone { TimeZone(identifier: timeZone) ?? TimeZone(identifier: "UTC") ?? .current }

    /// Days in date order (stable for days sharing a date).
    var orderedDays: [TripDay] {
        days.enumerated().sorted { a, b in
            a.element.date == b.element.date ? a.offset < b.offset : a.element.date < b.element.date
        }.map(\.element)
    }

    func place(id: String?) -> TripPlace? {
        guard let id else { return nil }
        return places.first { $0.id == id }
    }

    func hotel(id: String?) -> TripHotel? {
        guard let id else { return nil }
        return hotels.first { $0.id == id }
    }

    func transport(id: String?) -> TripTransport? {
        guard let id else { return nil }
        return transports.first { $0.id == id }
    }

    func expense(id: String?) -> TripExpense? {
        guard let id else { return nil }
        return expenses.first { $0.id == id }
    }

    func view(id: String?) -> TripView? {
        guard let id else { return nil }
        return views.first { $0.id == id }
    }

    /// Views shown inside a day; nil gives the trip-wide ones (the Views section).
    func views(forDay dayID: String?) -> [TripView] {
        views.filter { $0.dayId == dayID }
    }

    func day(id: String?) -> TripDay? {
        guard let id else { return nil }
        return days.first { $0.id == id }
    }

    /// 1-based position of a day in `orderedDays`.
    func dayNumber(of dayID: String) -> Int? {
        orderedDays.firstIndex { $0.id == dayID }.map { $0 + 1 }
    }

    /// `date` (an instant) falls within the trip's dates, in the trip's time zone.
    func contains(_ date: Date) -> Bool {
        let day = TripDate.string(from: date, timeZone: resolvedTimeZone)
        return startDate <= day && day <= endDate
    }

    /// The diary day for the calendar day `date` falls on in the trip's time zone.
    func day(for date: Date) -> TripDay? {
        let value = TripDate.string(from: date, timeZone: resolvedTimeZone)
        return orderedDays.first { $0.date == value }
    }

    /// Places a day visits: its route's places, else its moments' places, else where it stays.
    func placeIDs(for day: TripDay) -> [String] {
        if let route = day.route, !route.placeIds.isEmpty { return route.placeIds }
        let moments = day.moments.compactMap(\.placeId)
        if !moments.isEmpty { return moments }
        if let placeID = hotel(id: day.stayId)?.placeId { return [placeID] }
        return []
    }

    /// The line drawn for a day: its drawn `path`, else its route's places in order. Empty for stay days.
    func routeCoordinates(for day: TripDay) -> [TripCoordinate] {
        guard let route = day.route, route.kind != .stay else { return [] }
        if let path = route.path, path.count >= 2 { return path }
        return route.placeIds.compactMap { place(id: $0)?.coordinate }
    }

    /// What the camera frames for a day: its route, else the places it visits.
    func focusCoordinates(for day: TripDay) -> [TripCoordinate] {
        let route = routeCoordinates(for: day)
        if !route.isEmpty { return route }
        if let path = day.route?.path, !path.isEmpty { return path }
        return placeIDs(for: day).compactMap { place(id: $0)?.coordinate }
    }

    /// The day to open on near `coordinate`: the closest place within `radius` metres, then the
    /// first day visiting it on or after `today` (else the last before).
    func nearestDay(to coordinate: CLLocationCoordinate2D, within radius: CLLocationDistance = 50_000, today: Date = Date()) -> TripDay? {
        let here = TripCoordinate(coordinate)
        let candidates = places
            .map { ($0, $0.coordinate.distance(to: here)) }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
        let todayString = TripDate.string(from: today, timeZone: resolvedTimeZone)
        for (place, _) in candidates {
            let visiting = orderedDays.filter { placeIDs(for: $0).contains(place.id) || stayPlaceID(of: $0) == place.id }
            if let upcoming = visiting.first(where: { $0.date >= todayString }) { return upcoming }
            if let past = visiting.last { return past }
        }
        return nil
    }

    private func stayPlaceID(of day: TripDay) -> String? {
        hotel(id: day.stayId)?.placeId
    }

    /// Totals per currency, leaving out costs covered by a pass. The trip currency comes first.
    func expenseTotals(category: TripExpenseCategory? = nil) -> [TripCurrencyTotal] {
        var totals: [String: Double] = [:]
        for expense in expenses where !expense.isCovered && (category == nil || expense.category == category) {
            totals[expense.amount.currency, default: 0] += expense.amount.amount
        }
        return totals.map { TripCurrencyTotal(currency: $0.key, amount: $0.value) }
            .sorted { a, b in
                if a.currency == currency { return true }
                if b.currency == currency { return false }
                return a.currency < b.currency
            }
    }

    /// Expenses a pass covers.
    func expensesCovered(by passID: String) -> [TripExpense] {
        expenses.filter { $0.coveredByExpenseId == passID }
    }
}

// MARK: - Plans

public extension TripDocument {
    /// Trip-wide plans, in document order.
    var tripPlans: [TripPlan] { plans.filter { $0.scope == .trip } }

    /// The day plans deciding `date`.
    func dayPlans(on date: String) -> [TripPlan] {
        plans.filter { $0.scope == .day && $0.date == date }
    }

    func plan(id: String?) -> TripPlan? {
        guard let id else { return nil }
        return plans.first { $0.id == id }
    }

    /// The trip as one reader follows it (mirrors the server's `activeTripDocument`): records of
    /// the options they didn't pick are left out, with the places only those records visit, and
    /// references to them are cleared. Plans stay, so the reader can switch.
    func following(_ selections: [String: String]) -> TripDocument {
        guard !plans.isEmpty else { return self }
        let chosen = Set(plans.compactMap { $0.selectedOptionID(in: selections) })
        func active(_ optionID: String?) -> Bool { optionID.map(chosen.contains) ?? true }
        let droppedDays = Set(days.filter { !active($0.planOptionId) }.map(\.id))
        let droppedHotels = Set(hotels.filter { !active($0.planOptionId) }.map(\.id))
        let droppedTransports = Set(transports.filter { !active($0.planOptionId) }.map(\.id))
        let droppedExpenses = Set(expenses.filter { !active($0.planOptionId) }.map(\.id))

        var result = self
        result.days = days.filter { active($0.planOptionId) }.map { day in
            var day = day
            if let stay = day.stayId, droppedHotels.contains(stay) { day.stayId = nil }
            day.transportIds.removeAll(where: droppedTransports.contains)
            return day
        }
        result.hotels = hotels.filter { active($0.planOptionId) }
        result.transports = transports.filter { active($0.planOptionId) }
        result.expenses = expenses.filter { active($0.planOptionId) }.map { expense in
            var expense = expense
            if let day = expense.dayId, droppedDays.contains(day) { expense.dayId = nil }
            if let linked = expense.linkedId, droppedHotels.contains(linked) || droppedTransports.contains(linked) { expense.linkedId = nil }
            if let pass = expense.coveredByExpenseId, droppedExpenses.contains(pass) { expense.coveredByExpenseId = nil }
            return expense
        }
        result.notes = notes.filter { active($0.planOptionId) }
        result.views = views.filter { active($0.planOptionId) && !($0.dayId.map(droppedDays.contains) ?? false) }

        // A place stays unless every record that visits it was left out.
        let stillVisited = result.visitedPlaceIDs
        let hidden = visitedPlaceIDs.subtracting(stillVisited)
        result.places = places.filter { !hidden.contains($0.id) }
        return result
    }

    /// Places the days, stays and transport refer to.
    private var visitedPlaceIDs: Set<String> {
        var ids = Set<String>()
        for day in days {
            ids.formUnion(day.route?.placeIds ?? [])
            ids.formUnion(day.moments.compactMap(\.placeId))
        }
        ids.formUnion(hotels.compactMap(\.placeId))
        for segment in transports.flatMap(\.options).flatMap(\.segments) {
            if let from = segment.fromPlaceId { ids.insert(from) }
            if let to = segment.toPlaceId { ids.insert(to) }
        }
        return ids
    }
}

// MARK: - Editing

public extension TripDocument {
    /// A new record id: `<prefix>-<8 random hex>`.
    static func makeID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())"
    }

    mutating func upsert(_ place: TripPlace) { Self.upsert(place, into: &places) }
    mutating func upsert(_ transport: TripTransport) { Self.upsert(transport, into: &transports) }
    mutating func upsert(_ hotel: TripHotel) { Self.upsert(hotel, into: &hotels) }
    mutating func upsert(_ expense: TripExpense) { Self.upsert(expense, into: &expenses) }
    mutating func upsert(_ note: TripNote) { Self.upsert(note, into: &notes) }
    mutating func upsert(_ view: TripView) { Self.upsert(view, into: &views) }

    /// Replaces a day by id or inserts it in date order.
    mutating func upsert(_ day: TripDay) {
        if let index = days.firstIndex(where: { $0.id == day.id }) {
            days[index] = day
        } else {
            let index = days.firstIndex { $0.date > day.date } ?? days.endIndex
            days.insert(day, at: index)
        }
    }

    private static func upsert<T: Identifiable>(_ item: T, into items: inout [T]) where T.ID == String {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    /// Deletes a record and clears every reference to it, so the document stays valid.
    mutating func remove(_ collection: TripCollection, id: String) {
        switch collection {
        case .places:
            places.removeAll { $0.id == id }
            for i in days.indices {
                days[i].route?.placeIds.removeAll { $0 == id }
                for j in days[i].moments.indices where days[i].moments[j].placeId == id { days[i].moments[j].placeId = nil }
            }
            for i in hotels.indices where hotels[i].placeId == id { hotels[i].placeId = nil }
            for i in transports.indices {
                for j in transports[i].options.indices {
                    for k in transports[i].options[j].segments.indices {
                        if transports[i].options[j].segments[k].fromPlaceId == id { transports[i].options[j].segments[k].fromPlaceId = nil }
                        if transports[i].options[j].segments[k].toPlaceId == id { transports[i].options[j].segments[k].toPlaceId = nil }
                    }
                }
            }
        case .days:
            days.removeAll { $0.id == id }
            for i in expenses.indices where expenses[i].dayId == id { expenses[i].dayId = nil }
            // The day's views move to the trip's Views section.
            for i in views.indices where views[i].dayId == id { views[i].dayId = nil }
        case .transports:
            transports.removeAll { $0.id == id }
            for i in days.indices { days[i].transportIds.removeAll { $0 == id } }
            for i in expenses.indices where expenses[i].linkedId == id { expenses[i].linkedId = nil }
        case .hotels:
            hotels.removeAll { $0.id == id }
            for i in days.indices where days[i].stayId == id { days[i].stayId = nil }
            for i in expenses.indices where expenses[i].linkedId == id { expenses[i].linkedId = nil }
        case .expenses:
            expenses.removeAll { $0.id == id }
            for i in expenses.indices where expenses[i].coveredByExpenseId == id { expenses[i].coveredByExpenseId = nil }
        case .notes:
            notes.removeAll { $0.id == id }
        case .views:
            views.removeAll { $0.id == id }
        case .plans:
            // The plan's alternatives go with it.
            guard let plan = plans.first(where: { $0.id == id }) else { return }
            plans.removeAll { $0.id == id }
            let options = Set(plan.options.map(\.id))
            func tagged(_ optionID: String?) -> Bool { optionID.map(options.contains) ?? false }
            for day in days where tagged(day.planOptionId) { remove(.days, id: day.id) }
            for transport in transports where tagged(transport.planOptionId) { remove(.transports, id: transport.id) }
            for hotel in hotels where tagged(hotel.planOptionId) { remove(.hotels, id: hotel.id) }
            for expense in expenses where tagged(expense.planOptionId) { remove(.expenses, id: expense.id) }
            notes.removeAll { tagged($0.planOptionId) }
            views.removeAll { tagged($0.planOptionId) }
        }
    }
}

extension KeyedDecodingContainer {
    /// Seat classes are optional, so an unknown one is dropped rather than failing the trip.
    func decodeLenientSeatClass(forKey key: Key) -> TripSeatClass? {
        guard let raw = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return TripSeatClass(rawValue: raw)
    }
}
