import Testing
@testable import SummaryKit

struct XPostDateCleanerTests {
    @Test func removesBracketedAndInlineDates() {
        #expect(XPostDateCleaner.removing(["2026-10-28"], from: "Daily Podcast (2026-10-28)") == "Daily Podcast")
        #expect(XPostDateCleaner.removing(["Oct 28, 2026"], from: "Daily Briefing — Oct 28, 2026") == "Daily Briefing")
        #expect(XPostDateCleaner.removing(["2026-10-28", "9:00 AM"],
                                          from: "Today on 2026-10-28 at 9:00 AM we cover Swift 6.2.")
                == "Today we cover Swift 6.2.")
        #expect(XPostDateCleaner.removing(["2026年10月28日"], from: "OpenAI 在 2026年10月28日 发布了 GPT-6。")
                == "OpenAI 发布了 GPT-6。")
    }

    @Test func ignoresMentionsThatAreNotDates() {
        #expect(XPostDateCleaner.removing(["Rust 2024 edition"], from: "Rust 2024 edition explained")
                == "Rust 2024 edition explained")
        #expect(XPostDateCleaner.removing(["iOS 26", "6.2"], from: "Apple ships iOS 26 and Swift 6.2.")
                == "Apple ships iOS 26 and Swift 6.2.")
    }

    @Test func keepsTextWhenEverythingWouldBeRemoved() {
        #expect(XPostDateCleaner.removing(["2026-10-28"], from: "2026-10-28") == "2026-10-28")
    }
}
