import Foundation
import Testing
@testable import SummaryKit

struct GenerationOptionsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "GenerationOptionsStoreTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func loadsDefaultsWhenNothingSaved() {
        #expect(GenerationOptionsStore.load(from: makeDefaults()) == GenerationOptions())
    }

    @Test func roundTripsSavedOptions() {
        let defaults = makeDefaults()
        let options = GenerationOptions(language: .ja, imageStyle: .illustration, ttl: .never, visibility: .private)
        GenerationOptionsStore.save(options, to: defaults)
        #expect(GenerationOptionsStore.load(from: defaults) == options)

        let days = GenerationOptions(language: .en, imageStyle: .graphic, ttl: .days(30), visibility: .public)
        GenerationOptionsStore.save(days, to: defaults)
        #expect(GenerationOptionsStore.load(from: defaults) == days)
    }
}
