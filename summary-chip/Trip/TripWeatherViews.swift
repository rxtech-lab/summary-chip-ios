import SummaryKit
import SwiftUI

extension EnvironmentValues {
    /// The trip's forecasts, as the backend last stored them (`TripEditorModel.weather`).
    @Entry var tripWeather: TripWeather = .empty
}

/// Which dates forecasts can cover: today and the next 15 days.
enum TripWeatherWindow {
    static let days = 16

    static func isForecastable(_ date: String, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let format = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        let today = now.formatted(format)
        guard let last = calendar.date(byAdding: .day, value: days - 1, to: now)?.formatted(format) else { return false }
        return date >= today && date <= last
    }
}

// MARK: - Day card row

/// The day's forecast in its card: condition, high and low, and chance of rain, for each of its
/// places (up to two). Tapping it opens the day's forecast. Hidden until there is one.
struct TripDayWeatherRow: View {
    let day: TripDay
    let title: String
    @Environment(\.tripWeather) private var weather
    @State private var showsDetail = false

    var body: some View {
        if let dayWeather = weather.day(id: day.id, date: day.date) {
            let forecasts = Array(dayWeather.locations.filter { $0.forecast != nil }.prefix(2))
            if !forecasts.isEmpty {
                Button { showsDetail = true } label: {
                    HStack(spacing: 10) {
                        // One line per place, so nothing has to be cut short on a narrow card.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(forecasts) { location in
                                TripDayWeatherSummary(location: location, showsName: dayWeather.locations.count > 1)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("Shows the day's forecast"))
                .accessibilityIdentifier("trip-day-weather-\(day.id)")
                .sensoryFeedback(.selection, trigger: showsDetail) { _, new in new }
                .sheet(isPresented: $showsDetail) {
                    TripDayWeatherSheet(title: title, dayWeather: dayWeather, updatedAt: weather.updatedAt)
                }
            }
        }
    }
}

/// "🌧 Kyoto · Rain        14° – 21°  ☂︎ 80%": the place (when the day has several), the condition,
/// and the numbers, which are never truncated; a long name wraps instead.
private struct TripDayWeatherSummary: View {
    let location: TripWeatherLocation
    let showsName: Bool

    var body: some View {
        if let forecast = location.forecast {
            HStack(spacing: 8) {
                Image(systemName: forecast.condition.systemImage)
                    .symbolRenderingMode(.multicolor)
                    .font(.body)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Group {
                    if showsName {
                        Text("\(Text(location.name).fontWeight(.semibold)) · \(Text(forecast.condition.title).foregroundStyle(conditionColor(forecast)))")
                    } else {
                        Text(forecast.condition.title)
                            .fontWeight(.semibold)
                            .foregroundStyle(conditionColor(forecast))
                    }
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if let range = WeatherText.shortRange(low: forecast.low, high: forecast.high) {
                        Text(range).monospacedDigit()
                    }
                    if let chance = WeatherText.chance(forecast.precipitationChance), (forecast.precipitationChance ?? 0) >= 20 {
                        Label(chance, systemImage: "umbrella.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.blue)
                            .monospacedDigit()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityText(forecast)))
        }
    }

    private func conditionColor(_ forecast: DailyWeather) -> Color {
        forecast.condition.isBad ? .orange : .primary
    }

    private func accessibilityText(_ forecast: DailyWeather) -> String {
        [showsName ? location.name : nil, forecast.condition.title, WeatherText.range(low: forecast.low, high: forecast.high),
         WeatherText.chance(forecast.precipitationChance).map { String(localized: "\($0) chance of rain") }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Day forecast sheet

struct TripDayWeatherSheet: View {
    let title: String
    let dayWeather: TripDayWeather
    let updatedAt: Date?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TripDayWeatherList(dayWeather: dayWeather)
                    if let updatedAt {
                        Text("Updated \(updatedAt, format: .relative(presentation: .named))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("You'll get tomorrow's forecast the evening before each day, and an alert when the next 30 minutes turn bad.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Each place of a day with its forecast; shared by the weather sheet and the day's details.
struct TripDayWeatherList: View {
    let dayWeather: TripDayWeather

    var body: some View {
        VStack(spacing: 10) {
            ForEach(dayWeather.locations) { location in
                TripWeatherLocationRow(location: location)
            }
        }
    }
}

private struct TripWeatherLocationRow: View {
    let location: TripWeatherLocation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: location.forecast?.condition.systemImage ?? "cloud")
                .symbolRenderingMode(.multicolor)
                .font(.title2)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(location.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if let range = WeatherText.range(low: location.forecast?.low, high: location.forecast?.high) {
                        Text(range).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
                if let forecast = location.forecast {
                    Text(forecast.condition.title)
                        .font(.subheadline)
                        .foregroundStyle(forecast.condition.isBad ? Color.orange : Color.secondary)
                    details(forecast)
                } else {
                    Text("No forecast yet. Forecasts cover the next 16 days.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func details(_ forecast: DailyWeather) -> some View {
        let items: [(String, String)] = [
            WeatherText.chance(forecast.precipitationChance).map { ("umbrella", $0) },
            WeatherText.precipitation((forecast.precipitation ?? 0) > 0 ? forecast.precipitation : nil).map { ("drop", $0) },
            WeatherText.speed(forecast.gustsMax).map { ("wind", $0) },
            forecast.uvIndexMax.map { ("sun.max", String(localized: "UV \(Int($0.rounded()))")) },
        ].compactMap { $0 }
        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(items, id: \.0) { item in
                    Label(item.1, systemImage: item.0)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Now

/// During the trip's daytime: the weather where the reader is, and what the next 30 minutes bring.
struct TripWeatherNowBanner: View {
    /// The trip's time zone, for when the change comes.
    let timeZone: TimeZone
    @Environment(\.tripWeather) private var weather

    var body: some View {
        if let now = weather.now {
            let next = now.next30Minutes
            let changes = next.condition != now.condition
            HStack(spacing: 12) {
                Image(systemName: (changes ? next.condition : now.condition).systemImage)
                    .symbolRenderingMode(.multicolor)
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(now.name) · \([WeatherText.temperature(now.temperature), now.condition.title].compactMap { $0 }.joined(separator: " "))")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Group {
                        if changes {
                            Text("\(next.condition.title) from \(next.at, format: Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))")
                        } else {
                            Text("No change in the next 30 minutes")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(changes && next.condition.isBad ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.summaryCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("trip-weather-now")
        }
    }
}
