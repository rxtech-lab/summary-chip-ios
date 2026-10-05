import Foundation
import Observation
import SummaryKit

/// The currency trip costs are also shown in, and the exchange rates to get there. The choice is a
/// preference for every trip on this device; rates come from the open ExchangeRate-API feed and are
/// kept for 12 hours so totals still convert offline.
@Observable
final class CurrencyConverter {
    static let shared = CurrencyConverter()

    struct Rates: Codable, Equatable {
        var base: String
        /// Units of each currency per one unit of `base`.
        var rates: [String: Double]
        /// When the feed last published these rates.
        var publishedAt: Date
        var fetchedAt: Date
    }

    static let attributionURL = URL(string: "https://www.exchangerate-api.com")!

    private(set) var target: String?
    private(set) var rates: Rates?
    private(set) var isLoading = false
    private(set) var lastError: String?

    private static let targetKey = "trip-conversion-currency"
    private static let maxAge: TimeInterval = 12 * 3600

    init() {
        target = UserDefaults.standard.string(forKey: Self.targetKey)
        rates = target.flatMap(Self.cached)
    }

    /// Turns conversion on into `currency`, or off with nil.
    func setTarget(_ currency: String?) {
        guard currency != target else { return }
        target = currency
        UserDefaults.standard.set(currency, forKey: Self.targetKey)
        rates = currency.flatMap(Self.cached)
        lastError = nil
    }

    func refreshIfNeeded() async {
        guard target != nil else { return }
        if let rates, Date().timeIntervalSince(rates.fetchedAt) < Self.maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard let target, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        struct Response: Decodable {
            let result: String
            let rates: [String: Double]?
            let time_last_update_unix: TimeInterval?
        }
        do {
            guard let url = URL(string: "https://open.er-api.com/v6/latest/\(target)") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard response.result == "success", let map = response.rates else { throw URLError(.badServerResponse) }
            let fresh = Rates(
                base: target,
                rates: map,
                publishedAt: response.time_last_update_unix.map(Date.init(timeIntervalSince1970:)) ?? Date(),
                fetchedAt: Date()
            )
            // The user may have picked another currency while this was loading.
            guard self.target == target else { return }
            rates = fresh
            lastError = nil
            if let encoded = try? JSONEncoder().encode(fresh) {
                UserDefaults.standard.set(encoded, forKey: Self.ratesKey(target))
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// `money` in the chosen currency; nil when conversion is off, it is already in that currency,
    /// or its rate is missing.
    func convert(_ money: TripMoney) -> TripMoney? {
        guard let target, money.currency != target, let amount = convertedAmount(money) else { return nil }
        return TripMoney(amount: amount, currency: target)
    }

    /// The sum of `totals` in the chosen currency; nil when conversion is off, there is nothing to
    /// convert, or a rate is missing.
    func convert(_ totals: [TripCurrencyTotal]) -> TripMoney? {
        guard let target, !totals.isEmpty, totals.contains(where: { $0.currency != target }) else { return nil }
        var sum = 0.0
        for total in totals {
            guard let amount = convertedAmount(total.money) else { return nil }
            sum += amount
        }
        return TripMoney(amount: sum, currency: target)
    }

    private func convertedAmount(_ money: TripMoney) -> Double? {
        guard let target else { return nil }
        if money.currency == target { return money.amount }
        guard let rates, rates.base == target, let rate = rates.rates[money.currency], rate > 0 else { return nil }
        return money.amount / rate
    }

    private static func ratesKey(_ base: String) -> String { "trip-exchange-rates.\(base)" }

    private static func cached(_ base: String) -> Rates? {
        UserDefaults.standard.data(forKey: ratesKey(base)).flatMap { try? JSONDecoder().decode(Rates.self, from: $0) }
    }
}
