import Foundation
import Testing
@testable import summary_chip

@MainActor
@Suite struct OnboardingTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "OnboardingTests.\(UUID())")!
    }

    @Test func firstLaunchShowsWelcomeThenNewFeatures() {
        let store = SummaryOnboardingStore(defaults: defaults())
        #expect(store.launchPages == EducationPage.welcome + EducationPage.features)
    }

    @Test func interruptedTourIsNotCompletedByEarlierPages() {
        let defaults = defaults()
        let store = SummaryOnboardingStore(defaults: defaults)
        store.acknowledge(EducationPage.welcome[0])
        store.acknowledge(EducationPage.welcome[1])
        #expect(!SummaryOnboardingStore(defaults: defaults).hasSeenWelcome)
    }

    @Test func completedWelcomeDoesNotAcknowledgeFeatures() {
        let defaults = defaults()
        let store = SummaryOnboardingStore(defaults: defaults)
        store.acknowledge(EducationPage.welcome.last!)
        let relaunched = SummaryOnboardingStore(defaults: defaults)
        #expect(relaunched.hasSeenWelcome)
        #expect(relaunched.launchPages == EducationPage.features)
    }

    @Test func acknowledgementSurvivesRelaunchAndNewFeaturesStayUnread() {
        let defaults = defaults()
        let store = SummaryOnboardingStore(defaults: defaults)
        store.acknowledge(EducationPage.welcome.last!)
        store.acknowledge(EducationPage.features[0])
        store.acknowledge(EducationPage.features[0])
        let relaunched = SummaryOnboardingStore(defaults: defaults)
        #expect(relaunched.launchPages.isEmpty)
        #expect(relaunched.readIDs.count == 1)
        let future = EducationPage(id: "future-feature", kind: .feature, title: "Future", message: "New", imageName: "WelcomeSiri")
        #expect(relaunched.unreadFeatures(from: EducationPage.features + [future]) == [future])
    }
}
