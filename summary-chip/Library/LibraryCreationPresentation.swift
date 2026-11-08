import SummaryKit
import SwiftUI

/// A podcast or audiobook flow started from the library or a chip.
enum LibraryCreation: Identifiable {
    case podcast(initialChip: Summary? = nil)
    case resumedPodcast(PodcastPlan, library: Bool)
    case audiobook
    case resumedAudiobook(AudiobookPlan)
    case audiobookJob(AudiobookJob)

    var id: String {
        switch self {
        case .podcast(let chip): "podcast:\(chip?.id ?? "")"
        case .resumedPodcast(let plan, _): "podcast-plan:\(plan.id)"
        case .audiobook: "audiobook"
        case .resumedAudiobook(let plan): "audiobook-plan:\(plan.id)"
        case .audiobookJob(let job): "audiobook-job:\(job.id)"
        }
    }
}

/// Presents `AppEnvironment.libraryCreation` from the root, above the compact/regular switch.
/// A sheet presented inside the library would close when an iPhone Duo folds or unfolds, because
/// the tab layout and the sidebar layout are different view trees; this one, and the plan sheet
/// nested in it, stays open.
struct LibraryCreationPresentation: ViewModifier {
    @Bindable var environment: AppEnvironment
    @State private var creations = 0

    func body(content: Content) -> some View {
        content
            .sheet(item: $environment.libraryCreation, onDismiss: refreshPlans) { creation in
                switch creation {
                case .podcast(let chip):
                    DailyPodcastGenerationSheet(api: environment.api, date: Date(), existing: nil, library: true, initialChip: chip, onGenerated: presentGenerated)
                case .resumedPodcast(let plan, let library):
                    DailyPodcastGenerationSheet(api: environment.api, date: Date(), existing: nil, library: library,
                                                resumingPlan: plan, onGenerated: presentGenerated)
                case .audiobook:
                    AudiobookGenerationSheet(api: environment.api, date: Date(), onGenerated: presentGenerated, onBackground: refreshPlans, onSaved: reloadFeed)
                case .resumedAudiobook(let plan):
                    AudiobookGenerationSheet(api: environment.api, date: Date(), resumingPlan: plan, onGenerated: presentGenerated,
                                             onBackground: refreshPlans, onSaved: reloadFeed)
                case .audiobookJob(let job):
                    AudiobookJobSheet(api: environment.api, job: job, onGenerated: presentGenerated, onChanged: refreshPlans)
                }
            }
            .onChange(of: environment.libraryCreation?.id) { _, id in if id != nil { creations += 1 } }
            .sensoryFeedback(.selection, trigger: creations)
    }

    private func presentGenerated(_ podcast: DailyPodcast) {
        let library = environment.library
        library.removePlannedPodcast(id: podcast.key)
        Task {
            await library.refreshPlannedPodcasts()
            if let id = podcast.summaryId, let chip = try? await environment.api.summary(id: id) {
                library.insert(chip)
            }
            try? await Task.sleep(for: .milliseconds(350))
            environment.podcastPlayer.present(podcast: podcast)
        }
    }

    private func refreshPlans() {
        Task { await environment.library.refreshPlannedPodcasts() }
    }

    private func reloadFeed() {
        Task { await environment.library.reload() }
    }
}
