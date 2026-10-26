import ImageIO
import SummaryKit
import SwiftUI
import UIKit
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
    let picks: [EditorialHeadline]
    let images: [String: UIImage]
}

private struct HeadlineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeadlineEntry {
        HeadlineEntry(date: .now, picks: [], images: [:])
    }

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
            var picks: [EditorialHeadline] = []
            var images: [String: UIImage] = [:]
            if await broker.hasSession() {
                let api = SummaryAPIClient(baseURL: configuration.apiBaseURL, tokenProvider: broker)
                if let result = try? await api.headlines() {
                    picks = result.widgetPicks()
                    // Widgets render a snapshot; artwork must finish loading before publishing it.
                    for pick in picks {
                        if let summary = try? await api.summary(id: pick.id),
                           let url = summary.tileImageUrl,
                           let image = await loadImage(url) {
                            images[pick.id] = image
                        }
                    }
                }
                // Recheck after artwork too, so a switched account cannot publish old content.
                if !(await broker.hasSession()) || (try? vault.load())?.subject != subject {
                    picks = []
                    images = [:]
                }
            }
            completion(Timeline(entries: [HeadlineEntry(date: .now, picks: picks, images: images)],
                                policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    private func loadImage(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct HeadlineWidget: Widget {
    let kind = "ChippyHeadline"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HeadlineProvider()) { entry in
            HeadlineWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.picks.first.map { SummaryLink.openInAppURL(summaryID: $0.id) })
                .privacySensitive()
        }
        .configurationDisplayName("Editor’s Picks")
        .description("Explore a daily selection of summaries and podcasts, with their cover images.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HeadlineWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HeadlineEntry

    private var visiblePicks: [EditorialHeadline] {
        Array(entry.picks.prefix(family == .systemLarge ? 4 : family == .systemMedium ? 2 : 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Editor’s Picks", systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                if family != .systemSmall, let date = entry.picks.first?.createdAt {
                    Spacer(minLength: 4)
                    Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            if visiblePicks.isEmpty {
                Text("Your next pick starts with a chip.").font(.headline)
                Text("Open Chippy to add a summary or podcast.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                GeometryReader { geometry in
                    let rows = family == .systemLarge ? 2 : 1
                    let columns = family == .systemSmall ? 1 : 2
                    let height = max(0, (geometry.size.height - CGFloat(rows - 1) * 10) / CGFloat(rows))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                        ForEach(visiblePicks) { pick in
                            Link(destination: SummaryLink.openInAppURL(summaryID: pick.id)) {
                                tile(pick, height: height)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(pick.title), \(pick.score) out of 100"))
                        }
                    }
                }
            }
        }
    }

    private func tile(_ pick: EditorialHeadline, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .frame(height: max(20, height * 0.48))
                .overlay {
                    if let image = entry.images[pick.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.accentColor.opacity(0.12)
                            Image(systemName: pick.kind == .podcast ? "waveform" : "doc.richtext")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(pick.title).font(.caption.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            Text("\(pick.score)/100").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(height: height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
