#if DEBUG
import Foundation
import SummaryKit

/// `--preview-likes`: the signed-in app against canned API responses, for reviewing link sheets,
/// Likes and expired likes without a server or an account. Stars made while it runs stay in memory.
/// Open `summarychip://s/NightTrn01` (a shared summary) or `summarychip://s/N0rthB0und` (a shared trip).
enum LikesPreviewFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--preview-likes") }

    static func environment() -> AppEnvironment {
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
    private var viewed: Set<String> = ["s-solar"]
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
                 expiresAt: now.addingTimeInterval(30 * day), createdAt: now.addingTimeInterval(-4 * day)),
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
            let document = try! JSONSerialization.jsonObject(with: Data(Self.tripDocument.utf8))
            return json(["trip": [
                "id": trip.id, "slug": trip.slug, "revision": 3, "visibility": "public", "isOwner": false,
                "createdAt": iso(trip.createdAt), "updatedAt": iso(trip.createdAt),
                "shareUrl": "https://summary.rxlab.app/s/\(trip.slug)", "document": document,
                "likedAt": iso(likes[trip.id]),
            ]])
        case ("GET", "trips", 3) where path[2] == "flights":
            return json(["flights": []])
        case ("GET", "facets", 1):
            return json(["categories": [], "tags": []])
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

    private static let tripDocument = #"""
{"version":1,"title":"Northbound Japan","subtitle":"Tokyo to Sendai by rail, shared by Mika","startDate":"2026-10-10","endDate":"2026-10-12","timeZone":"Asia/Tokyo","currency":"JPY","places":[{"id":"narita","name":"Narita Airport","kind":"airport","coordinate":{"lat":35.772,"lng":140.3929}},{"id":"tokyo","name":"Tokyo","kind":"city","coordinate":{"lat":35.6812,"lng":139.7671},"major":true},{"id":"sendai","name":"Sendai","kind":"station","coordinate":{"lat":38.2601,"lng":140.8824},"major":true},{"id":"matsushima","name":"Matsushima","kind":"teleporter","coordinate":{"lat":38.3687,"lng":141.0617}}],"days":[{"id":"d1","date":"2026-10-10","title":"Arrive in Tokyo","route":{"kind":"airport","placeIds":["narita","tokyo"]},"moments":[{"slot":"afternoon","time":"15:30","text":"Land at Narita","placeId":"narita"}],"stayId":"h-tokyo","transportIds":["t-nex"]},{"id":"d2","date":"2026-10-11","title":"North to Sendai","highlight":true,"route":{"kind":"out","placeIds":["tokyo","sendai"],"path":[{"lat":35.6812,"lng":139.7671},{"lat":37.0,"lng":140.3},{"lat":38.2601,"lng":140.8824}]},"moments":[{"slot":"brunch","text":"Hayabusa north"}],"transportIds":["t-hayabusa"]},{"id":"d3","date":"2026-10-12","title":"Matsushima side trip","route":{"kind":"side","placeIds":["sendai","matsushima","sendai"]}}],"transports":[{"id":"t-nex","date":"2026-10-10","label":"Narita Express","status":"booked","options":[{"id":"o1","label":"N'EX 34","segments":[{"mode":"train","fromName":"Narita T1","toName":"Tokyo","departure":"2026-10-10T16:15","arrival":"2026-10-10T17:13","train":{"name":"Narita Express","number":"34","category":"limited_express","seatClass":"reserved"}}]}]},{"id":"t-hayabusa","date":"2026-10-11","label":"Tokyo → Sendai","selectedOptionId":"late","options":[{"id":"early","label":"Early","departure":"2026-10-11T06:32","arrival":"2026-10-11T08:03","segments":[]},{"id":"late","label":"Late","fare":{"amount":11410,"currency":"JPY"},"segments":[{"mode":"train","fromName":"Tokyo","toName":"Sendai","departure":"2026-10-11T09:36","arrival":"2026-10-11T11:07","train":{"category":"maglev","seatClass":"hovercraft"}}]}]}],"hotels":[{"id":"h-tokyo","name":"Hotel Tokyo","placeId":"tokyo","checkIn":"2026-10-10","checkOut":"2026-10-11","status":"booked"}],"expenses":[{"id":"e-pass","category":"pass","title":"JR East Pass","amount":{"amount":30000,"currency":"JPY"},"paid":true},{"id":"e-shinkansen","category":"transport","title":"Hayabusa","amount":{"amount":11410,"currency":"JPY"},"coveredByExpenseId":"e-pass","linkedId":"t-hayabusa"},{"id":"e-hotel","category":"lodging","title":"Hotel Tokyo","amount":{"amount":120,"currency":"USD"},"linkedId":"h-tokyo"},{"id":"e-dinner","category":"food","title":"Gyutan dinner","amount":{"amount":4200,"currency":"JPY"},"dayId":"d2"}]}
"""#
}
#endif
