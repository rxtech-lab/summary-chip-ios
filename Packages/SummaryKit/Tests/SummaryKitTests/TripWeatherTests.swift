import Foundation
import Testing
@testable import SummaryKit

private let weatherJSON = """
{
  "updatedAt": "2026-10-12T03:00:00.000Z",
  "days": [
    { "dayId": "d1", "date": "2026-10-12", "locations": [
      { "placeId": "kyoto", "name": "Kyoto", "forecast": {
        "date": "2026-10-12", "condition": "heavy_rain", "weatherCode": 65, "high": 21.4, "low": 14.2,
        "precipitationChance": 80, "precipitation": 12.5, "windMax": 20, "gustsMax": 41, "uvIndexMax": 3,
        "sunrise": "2026-10-12T05:49", "sunset": "2026-10-12T17:21" } },
      { "placeId": "nara", "name": "Nara", "forecast": null }
    ] },
    { "dayId": null, "date": "2026-10-13", "locations": [
      { "placeId": null, "name": "Osaka", "forecast": { "date": "2026-10-13", "condition": "hail" } }
    ] }
  ],
  "now": {
    "dayId": "d1", "placeId": "kyoto", "name": "Kyoto", "condition": "cloudy", "temperature": 18.2,
    "next30Minutes": { "condition": "rain", "at": "2026-10-12T03:30:00.000Z" }
  }
}
"""

@Suite struct TripWeatherTests {
    @Test func decodesTripWeather() throws {
        let weather = try SummaryJSON.decoder().decode(TripWeather.self, from: Data(weatherJSON.utf8))
        #expect(weather.updatedAt == SummaryJSON.parseISO8601("2026-10-12T03:00:00.000Z"))
        #expect(weather.days.count == 2)
        let first = try #require(weather.day(id: "d1", date: "2026-10-12"))
        #expect(first.primary?.name == "Kyoto")
        #expect(first.primary?.forecast?.condition == .heavyRain)
        #expect(first.primary?.forecast?.condition.isBad == true)
        #expect(first.primary?.forecast?.high == 21.4)
        #expect(first.locations[1].forecast == nil)
        // A day without a record is found by its date; unknown conditions fall back.
        #expect(weather.day(id: "other", date: "2026-10-13")?.primary?.forecast?.condition == .unknown)
        #expect(weather.now?.name == "Kyoto")
        #expect(weather.now?.next30Minutes.condition == .rain)
        #expect(weather.now?.next30Minutes.at == SummaryJSON.parseISO8601("2026-10-12T03:30:00.000Z"))
    }

    @Test func decodesEmptyWeather() throws {
        let weather = try SummaryJSON.decoder().decode(TripWeather.self, from: Data(#"{ "updatedAt": null, "days": [], "now": null }"#.utf8))
        #expect(weather == .empty)
        #expect(WeatherCondition(rawValue: "partly_cloudy") == .partlyCloudy)
    }

    @Test func formatsTemperatures() {
        #expect(WeatherText.temperature(nil) == nil)
        #expect(WeatherText.temperature(21.4)?.contains("°") == true)
        #expect(WeatherText.range(low: nil, high: nil) == nil)
        #expect(WeatherText.shortRange(low: 14.2, high: 21.4, locale: Locale(identifier: "zh_Hans_CN")) == "14° – 21°")
        #expect(WeatherText.shortRange(low: 0, high: 100, locale: Locale(identifier: "en_US")) == "32° – 212°")
        #expect(WeatherText.shortRange(low: nil, high: nil) == nil)
        #expect(WeatherText.chance(80) == (0.8).formatted(.percent.precision(.fractionLength(0))))
    }
}
