import Foundation

// Swift mirror of the trip weather contract in `docs/weather.md`. The backend fetches forecasts
// and sends the weather alerts; the apps only read what it stored. Units are °C, mm and km/h;
// `WeatherText` formats them for the user's locale. Decoding is lenient like the trip document.

public enum WeatherCondition: String, TripLenientEnum {
    case clear
    case partlyCloudy = "partly_cloudy"
    case cloudy
    case fog
    case drizzle
    case rain
    case heavyRain = "heavy_rain"
    case freezingRain = "freezing_rain"
    case snow
    case heavySnow = "heavy_snow"
    case thunderstorm
    case strongWind = "strong_wind"
    case unknown
    public static let fallback: Self = .unknown

    public var title: String {
        switch self {
        case .clear: String(localized: "Clear", bundle: .module)
        case .partlyCloudy: String(localized: "Partly cloudy", bundle: .module)
        case .cloudy: String(localized: "Cloudy", bundle: .module)
        case .fog: String(localized: "Fog", bundle: .module)
        case .drizzle: String(localized: "Drizzle", bundle: .module)
        case .rain: String(localized: "Rain", bundle: .module)
        case .heavyRain: String(localized: "Heavy rain", bundle: .module)
        case .freezingRain: String(localized: "Freezing rain", bundle: .module)
        case .snow: String(localized: "Snow", bundle: .module)
        case .heavySnow: String(localized: "Heavy snow", bundle: .module)
        case .thunderstorm: String(localized: "Thunderstorm", bundle: .module)
        case .strongWind: String(localized: "Strong wind", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .clear: "sun.max.fill"
        case .partlyCloudy: "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .freezingRain: "cloud.sleet.fill"
        case .snow, .heavySnow: "cloud.snow.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        case .strongWind: "wind"
        case .unknown: "cloud"
        }
    }

    /// Rain, snow, gales and worse: what the alerts warn about.
    public var isBad: Bool {
        switch self {
        case .rain, .heavyRain, .freezingRain, .snow, .heavySnow, .thunderstorm, .strongWind: true
        default: false
        }
    }
}

/// One location's forecast for one day.
public struct DailyWeather: Codable, Sendable, Hashable {
    /// The location's local date, `YYYY-MM-DD`.
    public var date: String
    public var condition: WeatherCondition
    public var high: Double?
    public var low: Double?
    /// 0–100.
    public var precipitationChance: Double?
    /// mm over the day.
    public var precipitation: Double?
    /// km/h.
    public var windMax: Double?
    public var gustsMax: Double?
    public var uvIndexMax: Double?
    /// The location's wall-clock time, `YYYY-MM-DDTHH:mm`.
    public var sunrise: String?
    public var sunset: String?

    public init(
        date: String, condition: WeatherCondition, high: Double? = nil, low: Double? = nil, precipitationChance: Double? = nil,
        precipitation: Double? = nil, windMax: Double? = nil, gustsMax: Double? = nil, uvIndexMax: Double? = nil,
        sunrise: String? = nil, sunset: String? = nil
    ) {
        self.date = date; self.condition = condition; self.high = high; self.low = low
        self.precipitationChance = precipitationChance; self.precipitation = precipitation; self.windMax = windMax
        self.gustsMax = gustsMax; self.uvIndexMax = uvIndexMax; self.sunrise = sunrise; self.sunset = sunset
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        condition = try c.decodeIfPresent(WeatherCondition.self, forKey: .condition) ?? .unknown
        high = try c.decodeIfPresent(Double.self, forKey: .high)
        low = try c.decodeIfPresent(Double.self, forKey: .low)
        precipitationChance = try c.decodeIfPresent(Double.self, forKey: .precipitationChance)
        precipitation = try c.decodeIfPresent(Double.self, forKey: .precipitation)
        windMax = try c.decodeIfPresent(Double.self, forKey: .windMax)
        gustsMax = try c.decodeIfPresent(Double.self, forKey: .gustsMax)
        uvIndexMax = try c.decodeIfPresent(Double.self, forKey: .uvIndexMax)
        sunrise = try c.decodeIfPresent(String.self, forKey: .sunrise)
        sunset = try c.decodeIfPresent(String.self, forKey: .sunset)
    }
}

/// A place a day visits, with its forecast (nil while it's beyond the forecast range or not fetched yet).
public struct TripWeatherLocation: Codable, Sendable, Hashable, Identifiable {
    public var placeId: String?
    public var name: String
    public var forecast: DailyWeather?

    public init(placeId: String? = nil, name: String, forecast: DailyWeather? = nil) {
        self.placeId = placeId; self.name = name; self.forecast = forecast
    }

    public var id: String { placeId ?? name }
}

public struct TripDayWeather: Codable, Sendable, Hashable, Identifiable {
    /// The day record's id; nil for a trip without days (one entry per date).
    public var dayId: String?
    public var date: String
    public var locations: [TripWeatherLocation]

    public init(dayId: String?, date: String, locations: [TripWeatherLocation]) {
        self.dayId = dayId; self.date = date; self.locations = locations
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayId = try c.decodeIfPresent(String.self, forKey: .dayId)
        date = try c.decode(String.self, forKey: .date)
        locations = try c.decodeIfPresent([TripWeatherLocation].self, forKey: .locations) ?? []
    }

    public var id: String { dayId ?? date }
    /// The day's first place that has a forecast.
    public var primary: TripWeatherLocation? { locations.first { $0.forecast != nil } }
}

/// During the trip's daytime: the weather where the reader is and in the next 30 minutes.
public struct TripWeatherNow: Codable, Sendable, Hashable {
    public struct Next: Codable, Sendable, Hashable {
        public var condition: WeatherCondition
        /// When it starts.
        public var at: Date

        public init(condition: WeatherCondition, at: Date) {
            self.condition = condition; self.at = at
        }
    }

    public var dayId: String?
    public var placeId: String?
    public var name: String
    public var condition: WeatherCondition
    public var temperature: Double?
    public var next30Minutes: Next

    public init(dayId: String?, placeId: String?, name: String, condition: WeatherCondition, temperature: Double?, next30Minutes: Next) {
        self.dayId = dayId; self.placeId = placeId; self.name = name; self.condition = condition
        self.temperature = temperature; self.next30Minutes = next30Minutes
    }
}

/// `GET /api/v1/trips/:id/weather`.
public struct TripWeather: Codable, Sendable, Hashable {
    /// When a forecast was last fetched; nil before the first one.
    public var updatedAt: Date?
    public var days: [TripDayWeather]
    public var now: TripWeatherNow?

    public init(updatedAt: Date? = nil, days: [TripDayWeather] = [], now: TripWeatherNow? = nil) {
        self.updatedAt = updatedAt; self.days = days; self.now = now
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        days = try c.decodeIfPresent([TripDayWeather].self, forKey: .days) ?? []
        now = try? c.decodeIfPresent(TripWeatherNow.self, forKey: .now)
    }

    public static let empty = TripWeather()

    /// The weather of a day record (by id), else of its date.
    public func day(id: String?, date: String) -> TripDayWeather? {
        days.first { id != nil && $0.dayId == id } ?? days.first { $0.date == date && $0.dayId == nil }
    }
}

/// Weather values in the user's units.
public enum WeatherText {
    /// "21°" (°F where the locale uses it).
    public static func temperature(_ celsius: Double?) -> String? {
        guard let celsius else { return nil }
        return Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// "14° – 21°".
    public static func range(low: Double?, high: Double?) -> String? {
        switch (temperature(low), temperature(high)) {
        case let (low?, high?): "\(low) – \(high)"
        case let (nil, high?): high
        case let (low?, nil): low
        default: nil
        }
    }

    /// "14° – 21°": degrees in the locale's unit without repeating it, for tight spaces.
    public static func shortRange(low: Double?, high: Double?, locale: Locale = .current) -> String? {
        let unit = UnitTemperature(forLocale: locale, usage: .weather)
        let degrees = { (celsius: Double?) in
            celsius.map { "\(Int(Measurement(value: $0, unit: UnitTemperature.celsius).converted(to: unit).value.rounded()))°" }
        }
        switch (degrees(low), degrees(high)) {
        case let (low?, high?): return "\(low) – \(high)"
        case let (nil, high?): return high
        case let (low?, nil): return low
        default: return nil
        }
    }

    /// "35 km/h" (mph where the locale uses it).
    public static func speed(_ kmh: Double?) -> String? {
        guard let kmh else { return nil }
        return Measurement(value: kmh, unit: UnitSpeed.kilometersPerHour)
            .formatted(.measurement(width: .abbreviated, usage: .wind, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// "6 mm" (inches where the locale uses them).
    public static func precipitation(_ mm: Double?) -> String? {
        guard let mm else { return nil }
        return Measurement(value: mm, unit: UnitLength.millimeters)
            .formatted(.measurement(width: .abbreviated, usage: .rainfall, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// "80%".
    public static func chance(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        return (percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
