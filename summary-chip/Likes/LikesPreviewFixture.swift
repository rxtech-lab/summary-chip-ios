#if DEBUG
import Foundation
import SummaryKit

/// `--preview-likes`: the signed-in app against canned API responses, for reviewing the library,
/// chat (with a rendered view), trips with flights, link sheets, Likes, expired likes and MCP keys
/// without a server or an account. Stars made while it runs stay in memory; the CI screenshot tests
/// run against it. Open `summarychip://s/NightTrn01` (a shared summary) or
/// `summarychip://s/N0rthB0und` (a shared trip).
enum LikesPreviewFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--preview-likes") }

    static func environment() -> AppEnvironment {
        TripTourPreviewPhotos.registerIfEnabled()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SummaryOnboardingStore.welcomeKey)
        defaults.set(EducationPage.features.map(\.id), forKey: SummaryOnboardingStore.readIDsKey)
        let token = SharedTokenBundle(accessToken: "preview-token", refreshToken: nil, idToken: nil,
                                      expiresAt: .now.addingTimeInterval(86_400), subject: "preview-user")
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [LikesPreviewProtocol.self]
        let environment = AppEnvironment.live(
            configuration: .live(),
            vault: InMemoryTokenVault(token),
            session: URLSession(configuration: session),
            authenticationState: .signedIn
        )
        environment.library.offline.clear()
        // Every run starts from the empty chat, not the previous run's transcript.
        environment.chatStore.remove(key: ChatTranscriptStore.libraryKey)
        return environment
    }
}

/// Serves `/api/v1/*` from the fixtures below.
nonisolated final class LikesPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = LikesPreviewStore.shared.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

nonisolated final class LikesPreviewStore: @unchecked Sendable {
    static let shared = LikesPreviewStore()

    private struct Item {
        var id: String
        var slug: String
        var kind = "summary"
        var title: String
        var summary: String
        var highlights: [String] = []
        var category: String
        var tags: [String]
        var source = "web"
        var sourceUrl: String?
        var siteName: String?
        var colors: [String]
        var emoji: String
        var accent: String
        var isOwner = false
        var expiresAt: Date?
        var isExpired = false
        var createdAt: Date
        var viewedAt: Date?
    }

    private let lock = NSLock()
    private var likes: [String: Date]
    private var viewed: Set<String> = ["s-solar", "trip-01"]
    /// The trip's plan options picked so far (plan id → option id).
    private var planSelections: [String: String] = [:]
    private let items: [Item]

    private init() {
        let now = Date.now
        let day: TimeInterval = 86_400
        items = [
            Item(id: "s-coffee", slug: "C0ffeeRst1", title: "Why specialty roasters are buying their own farms",
                 summary: "Small coffee roasters are investing directly in growers to secure quality beans as climate swings make harvests less predictable.",
                 highlights: ["Direct trade keeps more of the price with growers.", "Owning land gives roasters steadier supply."],
                 category: "Business", tags: ["coffee", "supply chain"], sourceUrl: "https://example.com/coffee", siteName: "Sprudge",
                 colors: ["#3E2723", "#8D6E63"], emoji: "☕️", accent: "#a1887f", isOwner: true,
                 expiresAt: now.addingTimeInterval(6 * day), createdAt: now.addingTimeInterval(-3 * 3600)),
            Item(id: "s-swift", slug: "SwiftCnc01", title: "Swift 6.2 makes strict concurrency approachable",
                 summary: "The release defaults new projects to main-actor isolation and adds clearer diagnostics, so most app code compiles without annotations.",
                 highlights: ["Main-actor-by-default removes most Sendable warnings.", "`@concurrent` marks work that should leave the main actor."],
                 category: "Technology", tags: ["swift", "concurrency"], source: "github", sourceUrl: "https://github.com/swiftlang/swift", siteName: "GitHub",
                 colors: ["#BF360C", "#FF7043"], emoji: "🕊️", accent: "#ff8a65", isOwner: true,
                 expiresAt: now.addingTimeInterval(25 * day), createdAt: now.addingTimeInterval(-26 * 3600)),
            Item(id: "s-sourdough", slug: "S0urD0ugh1", title: "The science of a better sourdough crumb",
                 summary: "Hydration, fermentation time and oven steam decide how open a loaf's crumb gets; a cold overnight proof gives bakers the most control.",
                 highlights: ["75% hydration is a forgiving starting point.", "A cold proof slows fermentation and deepens flavour."],
                 category: "Food", tags: ["baking", "sourdough"], source: "youtube", sourceUrl: "https://www.youtube.com/watch?v=sourdough", siteName: "YouTube",
                 colors: ["#4E342E", "#D7CCC8"], emoji: "🍞", accent: "#bcaaa4", isOwner: true,
                 expiresAt: now.addingTimeInterval(12 * day), createdAt: now.addingTimeInterval(-3 * day)),
            Item(id: "s-trains", slug: "NightTrn01", title: "Night trains are making a comeback across Europe",
                 summary: "New sleeper routes link Paris, Berlin, Vienna and Milan as travellers look for low-carbon alternatives to short flights. Operators are ordering modern carriages with private cabins, though tickets still cost more than budget airlines.",
                 highlights: ["Nightjet and European Sleeper are adding routes through 2027.", "Private cabins with showers are replacing six-berth couchettes.", "Fares remain higher than budget flights on most routes."],
                 category: "Travel", tags: ["rail", "europe", "climate"], sourceUrl: "https://example.com/night-trains", siteName: "The Guardian",
                 colors: ["#1A237E", "#5C6BC0"], emoji: "🚆", accent: "#7986cb",
                 expiresAt: now.addingTimeInterval(20 * day), createdAt: now.addingTimeInterval(-2 * day)),
            Item(id: "trip-01", slug: "N0rthB0und", kind: "trip", title: "Northbound Japan",
                 summary: "Three days from Narita to Sendai by rail, with a side trip to Matsushima.",
                 category: "Travel", tags: ["japan", "rail"], source: "text",
                 colors: ["#004D40", "#26A69A"], emoji: "🗾", accent: "#4db6ac",
                 expiresAt: now.addingTimeInterval(30 * day), createdAt: now.addingTimeInterval(-4 * day),
                 viewedAt: now.addingTimeInterval(-1 * 3600)),
            Item(id: "s-solar", slug: "S0larBalc1", title: "The quiet rise of balcony solar in Germany",
                 summary: "", category: "Science", tags: ["energy", "germany"], sourceUrl: "https://example.com/balcony-solar", siteName: "Clean Energy Wire",
                 colors: ["#F57F17", "#FFCA28"], emoji: "☀️", accent: "#ffb300",
                 expiresAt: now.addingTimeInterval(-1 * day), isExpired: true, createdAt: now.addingTimeInterval(-9 * day)),
        ]
        likes = ["s-solar": now.addingTimeInterval(-5 * day), "s-coffee": now.addingTimeInterval(-2 * 3600)]
    }

    func respond(to request: URLRequest) -> (Int, Data) {
        lock.withLock { route(request) }
    }

    private func route(_ request: URLRequest) -> (Int, Data) {
        guard let url = request.url else { return notFound }
        let parts = url.pathComponents.filter { $0 != "/" }
        let method = request.httpMethod ?? "GET"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return notFound }
        let path = Array(parts.dropFirst(2))
        let id = path.count > 1 ? path[1] : ""
        switch (method, path.first ?? "", path.count) {
        case ("GET", "summaries", 1):
            let liked = query.first { $0.name == "scope" }?.value == "liked"
            let listed = items.filter { item in
                liked ? likes[item.id] != nil : !item.isExpired && (item.isOwner || viewed.contains(item.id))
            }
            .sorted { sortDate($0, liked: liked) > sortDate($1, liked: liked) }
            return json(["items": listed.map(summary), "nextCursor": NSNull()])
        case ("GET", "summaries", 2):
            guard let item = items.first(where: { $0.id == id }), !item.isExpired else { return notFound }
            return json(summary(item))
        case ("PUT", "summaries", 3) where path[2] == "like":
            guard let item = items.first(where: { $0.id == id }), !item.isExpired else { return notFound }
            if likes[id] == nil { likes[id] = .now }
            return json(["likedAt": iso(likes[id])])
        case ("DELETE", "summaries", 3) where path[2] == "like":
            likes[id] = nil
            return json(["likedAt": NSNull()])
        case ("POST", "views", 1):
            let body = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
            let slug = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["slug"] as? String
            guard let index = items.firstIndex(where: { $0.slug == slug }), !items[index].isExpired else { return notFound }
            viewed.insert(items[index].id)
            return json(summary(items[index]))
        case ("GET", "trips", 2):
            guard let trip = items.first(where: { $0.id == id && $0.kind == "trip" }) else { return notFound }
            let document = TripTourPreviewPhotos.document(Data(Self.tripDocument.utf8))
            return json(["trip": [
                "id": trip.id, "slug": trip.slug, "revision": 3, "visibility": "public", "isOwner": false,
                "createdAt": iso(trip.createdAt), "updatedAt": iso(trip.createdAt),
                "shareUrl": "https://summary.rxlab.app/s/\(trip.slug)", "document": document,
                "likedAt": iso(likes[trip.id]), "planSelections": planSelections,
            ]])
        case ("PUT", "trips", 3) where path[2] == "plan-selections":
            let body = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
            let pick = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            guard let planID = pick["planId"] as? String else { return notFound }
            planSelections[planID] = pick["optionId"] as? String
            return json(["planSelections": planSelections])
        case ("GET", "trips", 3) where path[2] == "flights":
            return (200, Data(Self.tripFlights.utf8))
        case ("POST", "trips", 3) where path[2] == "tour":
            // No narration audio offline: the tour reads its subtitles at a calm pace.
            return json(TripTourPreviewPhotos.tour(Data(Self.tripTour.utf8)))
        case ("GET", "trips", 3) where path[2] == "weather":
            return json(["updatedAt": NSNull(), "days": [], "now": NSNull()])
        case ("GET", "facets", 1):
            return json(["categories": [], "tags": []])
        case ("GET", "api-keys", 1):
            return json(["items": [
                ["id": "key-claude", "name": "Claude Code on MacBook", "hint": "chippy_Ab3x…9fQz", "toolCallCount": 1284,
                 "summariesAddedCount": 37, "lastUsedAt": iso(.now.addingTimeInterval(-40 * 60)), "createdAt": iso(.now.addingTimeInterval(-60 * 86_400))],
                ["id": "key-desktop", "name": "Claude Desktop", "hint": "chippy_Q7mN…k2Lp", "toolCallCount": 212,
                 "summariesAddedCount": 4, "lastUsedAt": iso(.now.addingTimeInterval(-3 * 86_400)), "createdAt": iso(.now.addingTimeInterval(-20 * 86_400))],
            ]])
        case ("POST", "chat", 1):
            // The whole answer arrives at once; the app parses it as the same UI message stream.
            let lines = Self.chatEvents.split(separator: "\n").map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
            return (200, Data(lines.utf8))
        default:
            return notFound
        }
    }

    private func sortDate(_ item: Item, liked: Bool) -> Date {
        liked ? likes[item.id] ?? .distantPast : item.viewedAt ?? item.createdAt
    }

    private func summary(_ item: Item) -> [String: Any] {
        let shareUrl = "https://summary.rxlab.app/s/\(item.slug)"
        return [
            "id": item.id, "slug": item.slug, "kind": item.kind, "shareUrl": shareUrl, "ogImageUrl": NSNull(),
            "sourceType": item.source == "text" ? "text" : "url", "source": item.source,
            "sourceUrl": item.sourceUrl ?? NSNull(), "sourceTitle": item.isExpired ? NSNull() : item.title as Any,
            "siteName": item.siteName ?? NSNull(), "sourceFileUrl": NSNull(),
            "title": item.title, "summary": item.summary, "highlights": item.highlights,
            "category": item.category, "tags": item.tags, "keywords": [], "language": "en",
            "theme": ["colors": item.colors, "mode": "dark", "emoji": item.emoji, "accent": item.accent],
            "imageStyle": "graphic", "visibility": "public", "ttlDays": 30, "expiresAt": iso(item.expiresAt),
            "viewCount": 12, "isOwner": item.isOwner,
            "viewedAt": item.isOwner ? NSNull() : iso(item.viewedAt ?? item.createdAt),
            "likedAt": iso(likes[item.id]), "isExpired": item.isExpired,
            "createdAt": iso(item.createdAt), "updatedAt": iso(item.createdAt),
        ]
    }

    private func iso(_ date: Date?) -> Any {
        date.map { $0.ISO8601Format() } ?? NSNull()
    }

    private var notFound: (Int, Data) {
        (404, Data(#"{"error":{"code":"NOT_FOUND","message":"Not found"}}"#.utf8))
    }

    private func json(_ object: Any) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static let tripTour = #"""
{"tour":{"key":"0123456789abcdef0123456789abcdef","language":"en","voice":"en-US-Harper","createdAt":"2026-10-01T00:00:00.000Z","scenes":[
{"kind":"intro","dayId":null,"placeId":null,"transportId":null,"hotelId":null,"title":"North by rail","narration":"Welcome aboard. Over three unhurried days we fly into Narita, settle into Tokyo, then ride the Hayabusa north to Sendai and the pine islands of Matsushima.","audioPath":"/api/v1/trips/trip-01/tour/0123456789abcdef0123456789abcdef/scenes/0/audio"},
{"kind":"day","dayId":"d1","placeId":null,"transportId":null,"hotelId":null,"title":"Landing in Tokyo","narration":"October tenth, twenty twenty-six. Today we're traveling from Narita to Tokyo. Let's explore the city together, looking for the stories behind its streets and the little details that make a first evening memorable. We will discover the neighborhoods around Tokyo Station, noticing how the city unfolds from its railway heart. Take a moment to look around with me before we continue our journey north.","visuals":[{"textOffset":71,"placeId":"tokyo","photoIndex":null}],"audioPath":"/api/v1/trips/trip-01/tour/0123456789abcdef0123456789abcdef/scenes/1/audio"},
{"kind":"stay","dayId":"d1","placeId":"tokyo","transportId":null,"hotelId":"h-tokyo","title":"A night in Tokyo","narration":"Our first night is in Tokyo, close to the station, so tomorrow's early train is only a short walk away.","audioPath":"/api/v1/trips/trip-01/tour/0123456789abcdef0123456789abcdef/scenes/2/audio"},
{"kind":"day","dayId":"d2","placeId":null,"transportId":null,"hotelId":null,"title":"North on the Hayabusa","narration":"On Sunday we head north. The Hayabusa reaches Sendai in about ninety minutes, so we arrive in time for grilled beef tongue at lunch.","audioPath":"/api/v1/trips/trip-01/tour/0123456789abcdef0123456789abcdef/scenes/3/audio"},
{"kind":"place","dayId":"d2","placeId":"sendai","transportId":null,"hotelId":null,"title":"Sendai, city of trees","narration":"Sendai is the leafy capital of Tohoku, with wide avenues lined with zelkova trees and a lively arcade right by the station.","audioPath":"/api/v1/trips/trip-01/tour/0123456789abcdef0123456789abcdef/scenes/4/audio"},
{"kind":"day","dayId":"d3","placeId":null,"transportId":null,"hotelId":null,"title":"Matsushima Bay","narration":"Monday is for the bay. A short local train brings us to Matsushima, where more than two hundred pine-covered islands dot the water.","audioPath":"/api/v1/trips/trip-01/tour/0123456789abcdef0123456789abcdef/scenes/5/audio"},
{"kind":"outro","dayId":null,"placeId":null,"transportId":null,"hotelId":null,"title":"Until next time","narration":"That is our journey north: three days, two cities and one quiet bay. Safe travels, and enjoy every stop.","audioPath":"/api/v1/trips/trip-01/tour/0123456789abcdef0123456789abcdef/scenes/6/audio"}
]}}
"""#

    private static let tripDocument = #"""
{"version":1,"title":"Northbound Japan","subtitle":"Tokyo to Sendai by rail, shared by Mika","startDate":"2026-10-10","endDate":"2026-10-12","timeZone":"Asia/Tokyo","currency":"JPY","places":[{"id":"narita","name":"Narita Airport","kind":"airport","coordinate":{"lat":35.772,"lng":140.3929}},{"id":"tokyo","name":"Tokyo","kind":"city","coordinate":{"lat":35.6812,"lng":139.7671},"major":true},{"id":"sendai","name":"Sendai","kind":"station","coordinate":{"lat":38.2601,"lng":140.8824},"major":true},{"id":"matsushima","name":"Matsushima","kind":"teleporter","coordinate":{"lat":38.3687,"lng":141.0617}},{"id":"yamadera","name":"Yamadera","kind":"poi","coordinate":{"lat":38.3126,"lng":140.4374}}],"days":[{"id":"d1","date":"2026-10-10","title":"Arrive in Tokyo","route":{"kind":"airport","placeIds":["narita","tokyo"]},"moments":[{"slot":"afternoon","time":"15:30","text":"Land at Narita","placeId":"narita"}],"stayId":"h-tokyo","transportIds":["t-cx","t-nex"]},{"id":"d2","date":"2026-10-11","title":"North to Sendai","highlight":true,"route":{"kind":"out","placeIds":["tokyo","sendai"],"path":[{"lat":35.6812,"lng":139.7671},{"lat":37.0,"lng":140.3},{"lat":38.2601,"lng":140.8824}]},"moments":[{"slot":"brunch","text":"Hayabusa north"}],"transportIds":["t-hayabusa"]},{"id":"d3","date":"2026-10-12","title":"Matsushima side trip","route":{"kind":"side","placeIds":["sendai","matsushima","sendai"]},"planOptionId":"route-matsushima"},{"id":"d3-yamadera","date":"2026-10-12","title":"Yamadera mountain temple","route":{"kind":"side","placeIds":["sendai","yamadera","sendai"]},"moments":[{"slot":"morning","text":"Climb the 1,015 steps to Godaido","placeId":"yamadera"}],"planOptionId":"route-yamadera"}],"transports":[{"id":"t-cx","date":"2026-10-10","label":"Hong Kong → Tokyo","status":"booked","options":[{"id":"o-cx","label":"CX 520","segments":[{"mode":"flight","fromName":"Hong Kong","toName":"Narita","toPlaceId":"narita","departure":"2026-10-10T09:05","arrival":"2026-10-10T14:30","flight":{"airline":"Cathay Pacific","flightNumber":"CX520","fromIATA":"HKG","toIATA":"NRT","terminal":"1","seat":"42K","seatClass":"economy","bookingRef":"QX7P2M"}}]}]},{"id":"t-nex","date":"2026-10-10","label":"Narita Express","status":"booked","options":[{"id":"o1","label":"N'EX 34","segments":[{"mode":"train","fromName":"Narita T1","toName":"Tokyo","departure":"2026-10-10T16:15","arrival":"2026-10-10T17:13","train":{"name":"Narita Express","number":"34","category":"limited_express","seatClass":"reserved"}}]}]},{"id":"t-hayabusa","date":"2026-10-11","label":"Tokyo → Sendai","selectedOptionId":"late","options":[{"id":"early","label":"Early","departure":"2026-10-11T06:32","arrival":"2026-10-11T08:03","segments":[]},{"id":"late","label":"Late","fare":{"amount":11410,"currency":"JPY"},"segments":[{"mode":"train","fromName":"Tokyo","toName":"Sendai","departure":"2026-10-11T09:36","arrival":"2026-10-11T11:07","train":{"category":"maglev","seatClass":"hovercraft"}}]}]}],"hotels":[{"id":"h-tokyo","name":"Hotel Tokyo","placeId":"tokyo","checkIn":"2026-10-10","checkOut":"2026-10-11","status":"booked"}],"expenses":[{"id":"e-pass","category":"pass","title":"JR East Pass","amount":{"amount":30000,"currency":"JPY"},"paid":true},{"id":"e-shinkansen","category":"transport","title":"Hayabusa","amount":{"amount":11410,"currency":"JPY"},"coveredByExpenseId":"e-pass","linkedId":"t-hayabusa"},{"id":"e-hotel","category":"lodging","title":"Hotel Tokyo","amount":{"amount":120,"currency":"USD"},"linkedId":"h-tokyo"},{"id":"e-dinner","category":"food","title":"Gyutan dinner","amount":{"amount":4200,"currency":"JPY"},"dayId":"d2"}],"plans":[{"id":"plan-d3","title":"Day 3 route","scope":"day","date":"2026-10-12","options":[{"id":"route-matsushima","label":"Route 1 · Matsushima Bay","summary":"Island-dotted bay by the Senseki Line, oysters for lunch."},{"id":"route-yamadera","label":"Route 2 · Yamadera","summary":"Mountain temple an hour inland on the Senzan Line; more stairs, fewer crowds."}]}],"views":[{"id":"v-pass","title":"Rail pass or pay as you go?","spec":{"root":"root","elements":{"root":{"type":"Stack","props":{"gap":"medium"},"children":["stats","fares","chart","verdict"]},"stats":{"type":"Grid","props":{"columns":2},"children":["pass","fares-total"]},"pass":{"type":"Stat","props":{"label":"JR East Pass","value":30000,"format":"money","detail":"5 flexible days"}},"fares-total":{"type":"Stat","props":{"label":"Each fare by IC card","value":26730,"format":"money","tone":"positive","detail":"Saves ¥3,270"}},"fares":{"type":"Table","props":{"caption":"Fares on this trip","totalLabel":"Total","columns":[{"key":"leg","label":"Leg"},{"key":"train","label":"Train"},{"key":"fare","label":"Fare","align":"trailing","format":"money","total":true}],"rows":[{"cells":{"leg":"Narita → Tokyo","train":"N'EX","fare":3070}},{"cells":{"leg":"Tokyo → Sendai","train":"Hayabusa","fare":11410}},{"cells":{"leg":"Sendai ⇄ Matsushima","train":"Senseki Line","fare":840}},{"cells":{"leg":"Sendai → Tokyo","train":"Yamabiko","fare":11410}}]}},"chart":{"type":"BarChart","props":{"title":"Cost by option","format":"money","items":[{"label":"JR East Pass","value":30000},{"label":"Pay as you go","value":26730,"tone":"positive"}]}},"verdict":{"type":"Callout","props":{"tone":"tip","title":"Skip the pass","text":"Unless you add a day trip to Nikko, paying each fare with Suica is cheaper."}}}}}]}
"""#

    private static let tripFlights = #"""
{"flights":[{"transportId":"t-cx","optionId":"o-cx","segmentIndex":0,"flightId":"CX520-2026-10-10","flightNumber":"CX520","date":"2026-10-10","state":"found","flight":{"id":"CX520-2026-10-10","flightNumber":"CX520","date":"2026-10-10","status":"delayed","airline":{"name":"Cathay Pacific","iata":"CX"},"aircraft":"Airbus A350-900","departure":{"iata":"HKG","name":"Hong Kong International","city":"Hong Kong","timeZone":"Asia/Hong_Kong","coordinate":{"lat":22.308,"lng":113.9185},"scheduled":"2026-10-10T01:05:00Z","estimated":"2026-10-10T01:20:00Z","scheduledLocal":"2026-10-10T09:05","estimatedLocal":"2026-10-10T09:20","terminal":"1","gate":"23","checkInDesk":"B"},"arrival":{"iata":"NRT","name":"Narita International","city":"Tokyo","timeZone":"Asia/Tokyo","coordinate":{"lat":35.772,"lng":140.3929},"scheduled":"2026-10-10T05:30:00Z","estimated":"2026-10-10T05:40:00Z","scheduledLocal":"2026-10-10T14:30","estimatedLocal":"2026-10-10T14:40","terminal":"2","baggageBelt":"7"},"delayMinutes":15,"arrivalDelayMinutes":10}}]}
"""#

    /// The library chat's answer: a library search, a rendered view, then the text.
    private static let chatEvents = #"""
{"type":"start"}
{"type":"tool-input-available","toolCallId":"call-search","toolName":"searchSummaries","input":{"query":"japan rail"}}
{"type":"tool-output-available","toolCallId":"call-search","output":{"semantic":true,"results":[{"id":"trip-01","slug":"N0rthB0und","title":"Northbound Japan","summary":"Three days from Narita to Sendai by rail, with a side trip to Matsushima.","category":"Travel","tags":["japan","rail"],"shareUrl":"https://summary.rxlab.app/s/N0rthB0und"},{"id":"s-trains","slug":"NightTrn01","title":"Night trains are making a comeback across Europe","summary":"New sleeper routes link Paris, Berlin, Vienna and Milan.","category":"Travel","tags":["rail","europe"],"siteName":"The Guardian","shareUrl":"https://summary.rxlab.app/s/NightTrn01"}]}}
{"type":"tool-input-available","toolCallId":"call-ui","toolName":"renderUI","input":{"title":"Northbound Japan at a glance"}}
{"type":"tool-output-available","toolCallId":"call-ui","output":{"text":"Trip overview","ui":{"title":"Northbound Japan at a glance","currency":"JPY","spec":{"root":"root","elements":{"root":{"type":"Stack","props":{"gap":"medium"},"children":["stats","details","plan","note"]},"stats":{"type":"Grid","props":{"columns":3},"children":["days","trains","spend"]},"days":{"type":"Stat","props":{"label":"Days","value":3}},"trains":{"type":"Stat","props":{"label":"Trains","value":2,"detail":"1 booked"}},"spend":{"type":"Stat","props":{"label":"Spent","value":34210,"format":"money"}},"details":{"type":"Card","props":{"title":"Getting there"},"children":["facts"]},"facts":{"type":"KeyValue","props":{"items":[{"label":"Flight","value":"CX 520 · HKG → NRT"},{"label":"Status","value":"Delayed 15 min","tone":"warning"},{"label":"Hotel","value":"Hotel Tokyo, 1 night"}]}},"plan":{"type":"List","props":{"ordered":true,"items":["Land at Narita and take the N'EX to Tokyo","Hayabusa north to Sendai","Side trip to Matsushima Bay"]}},"note":{"type":"Callout","props":{"tone":"tip","text":"Your JR East Pass costs more than paying each fare. Skip it unless you add Nikko."}}}}}}}
{"type":"text-start","id":"text-1"}
{"type":"text-delta","id":"text-1","delta":"You saved **Northbound Japan**, a three-day rail trip from Narita to Sendai, and a piece on Europe's night trains.\n\nThe trip starts with **CX 520** into Narita, currently running about 15 minutes late, then the Narita Express into Tokyo. I've put the days, bookings and spending together in the view above."}
{"type":"text-end","id":"text-1"}
{"type":"finish"}
"""#
}
#endif
