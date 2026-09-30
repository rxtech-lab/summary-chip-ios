import Foundation

/// The options last used to generate a summary, stored in the App Group so the app, the share
/// extension and the iMessage extension all start from the same choices.
public enum GenerationOptionsStore {
    static let key = "lastGenerationOptions"

    public static var defaults: UserDefaults? { UserDefaults(suiteName: SummaryIdentifiers.appGroupIdentifier) }

    private struct Stored: Codable {
        var language: SummaryLanguage
        var imageStyle: ImageStyle
        /// `nil` means the link never expires.
        var ttlDays: Int?
        var visibility: SummaryVisibility
    }

    public static func load(from defaults: UserDefaults? = defaults) -> GenerationOptions {
        guard let data = defaults?.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return GenerationOptions() }
        let ttl: TTLOption = stored.ttlDays.map { TTLOption.allowedDays.contains($0) ? .days($0) : .default } ?? .never
        return GenerationOptions(language: stored.language, imageStyle: stored.imageStyle, ttl: ttl, visibility: stored.visibility)
    }

    public static func save(_ options: GenerationOptions, to defaults: UserDefaults? = defaults) {
        let stored = Stored(language: options.language, imageStyle: options.imageStyle, ttlDays: options.ttl.ttlDays, visibility: options.visibility)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults?.set(data, forKey: key)
    }
}
