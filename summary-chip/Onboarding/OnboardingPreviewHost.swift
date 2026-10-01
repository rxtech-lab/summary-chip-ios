#if DEBUG
import SwiftUI

/// Local simulator review without needing a live account or modifying production read state.
struct OnboardingPreviewHost: View {
    @State private var presentation: EducationPresentation?

    var body: some View {
        NavigationStack {
            List {
                Button("Welcome Tour") { presentation = .init(pages: EducationPage.welcome) }
                Button("What’s New") { presentation = .init(pages: EducationPage.features) }
            }
            .navigationTitle("Onboarding Preview")
            .sheet(item: $presentation) { flow in
                EducationSheet(pages: flow.pages, allowsDismissal: true) { presentation = nil }
            }
            .task { presentation = .init(pages: EducationPage.welcome + EducationPage.features) }
        }
        .tint(.indigo)
    }
}
#endif
