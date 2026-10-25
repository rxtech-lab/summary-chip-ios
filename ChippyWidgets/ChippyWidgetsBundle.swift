import SummaryKit
import SwiftUI
import WidgetKit

@main
struct ChippyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FlightLiveActivityWidget()
        HeadlineWidget()
    }
}

private struct HeadlineEntry: TimelineEntry {
    let date: Date
    let headline: EditorialHeadline?
}

private struct HeadlineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeadlineEntry { HeadlineEntry(date: .now, headline: nil) }

    func getSnapshot(in context: Context, completion: @escaping (HeadlineEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeadlineEntry>) -> Void) {
        Task {
            let configuration = SummaryConfiguration.live()
            let vault = SharedKeychainTokenVault(accessGroup: configuration.keychainAccessGroup)
            let subject = (try? vault.load())?.subject
            let broker = SharedTokenBroker(vault: vault, tokenURL: configuration.oauthTokenURL,
                                           clientID: configuration.oauthClientID)
            var headline: EditorialHeadline?
            if await broker.hasSession() {
                let api = SummaryAPIClient(baseURL: configuration.apiBaseURL, tokenProvider: broker)
                headline = try? await api.headlines().highlighted
                // A logout while the request was in flight must not publish the previous account's title.
                if !(await broker.hasSession()) || (try? vault.load())?.subject != subject { headline = nil }
            }
            completion(Timeline(entries: [HeadlineEntry(date: .now, headline: headline)],
                                policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

private struct HeadlineWidget: Widget {
    let kind = "ChippyHeadline"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HeadlineProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Label("Editor’s Pick", systemImage: "star.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let headline = entry.headline {
                    Text(headline.title).font(.headline).lineLimit(5)
                    Spacer(minLength: 0)
                    Text("\(headline.score)/100").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("Your next headline starts with a chip.").font(.headline)
                    Text("Open Chippy to add a summary or podcast.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(entry.headline.map { SummaryLink.openInAppURL(summaryID: $0.id) })
            .privacySensitive()
        }
        .configurationDisplayName("Today’s Headline")
        .description("The top summary or podcast from your recent chips.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
