import Foundation
import Testing
@testable import SummaryKit

@Suite struct FormattingTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func ttlOptionTitles() {
        #expect(TTLOption.allCases.map(\.title) == ["1 day", "3 days", "1 week", "1 month", "3 months", "1 year", "Never"])
        #expect(TTLOption(ttlDays: nil) == .never)
        #expect(TTLOption(ttlDays: 30).ttlDays == 30)
    }

    @Test func countdown() {
        #expect(TTLFormatter.countdown(until: nil, now: now) == "No expiry")
        #expect(TTLFormatter.countdown(until: now.addingTimeInterval(-1), now: now) == "Link expired")
        #expect(TTLFormatter.countdown(until: now.addingTimeInterval(3 * 86_400 + 5), now: now) == "Expires in 3d")
        #expect(TTLFormatter.countdown(until: now.addingTimeInterval(5 * 3600 + 30), now: now) == "Expires in 5h")
        #expect(TTLFormatter.countdown(until: now.addingTimeInterval(20), now: now) == "Expires in 1m")
        #expect(TTLFormatter.isExpiringSoon(now.addingTimeInterval(3600), now: now))
        #expect(!TTLFormatter.isExpiringSoon(now.addingTimeInterval(2 * 86_400), now: now))
    }

    @Test func dateSections() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dates = [now, now.addingTimeInterval(-86_400), now.addingTimeInterval(-3 * 86_400), now.addingTimeInterval(-30 * 86_400)]
        #expect(dates.map { DateSection.section(for: $0, now: now, calendar: calendar) } == [.today, .yesterday, .thisWeek, .earlier])
        let grouped = DateSection.group(dates.reversed(), now: now, calendar: calendar) { $0 }
        #expect(grouped.map(\.section) == [.today, .yesterday, .thisWeek, .earlier])
    }

    @Test func tileDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(SummaryDateFormatter.tile(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday")
        #expect(!SummaryDateFormatter.tile(now, now: now, calendar: calendar).isEmpty)
        #expect(SummaryDateFormatter.tile(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) != "Yesterday")
    }

    @Test func tokenBundleRoundTrip() throws {
        let bundle = SharedTokenBundle(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: Date(timeIntervalSince1970: 1_800_000_000), subject: "u")
        #expect(try TokenBundleCodec.decode(TokenBundleCodec.encode(bundle)) == bundle)
        #expect(bundle.hasSession)
    }

    @Test func brokerReturnsStoredTokenWithoutRefreshing() async throws {
        let vault = InMemoryTokenVault(SharedTokenBundle(accessToken: "live", refreshToken: "r", idToken: nil, expiresAt: Date().addingTimeInterval(3600), subject: nil))
        let broker = SharedTokenBroker(vault: vault, tokenURL: URL(string: "https://auth.invalid/token")!, clientID: "c", lockURL: FileManager.default.temporaryDirectory.appending(path: "test.lock"))
        #expect(try await broker.validAccessToken() == "live")
    }
}
