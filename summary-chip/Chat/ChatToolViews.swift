import SummaryKit
import SwiftUI

/// JSON views and web research each have a dedicated sheet instead of expanding the transcript.
struct ChatToolDetailSheet: View {
    let tool: ChatToolActivity
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var feedback = 0

    var body: some View {
        NavigationStack {
            Group {
                if let ui = tool.renderedUI {
                    ScrollView {
                        TripViewRenderer(spec: ui.spec, currency: ui.currency)
                            .padding()
                            .environment(\.openURL, OpenURLAction { url in
                                feedback += 1
                                openURL(url)
                                return .handled
                            })
                    }
                    .accessibilityIdentifier("chat-native-ui")
                } else {
                    List(tool.webReferences ?? []) { source in
                        Button {
                            feedback += 1
                            openURL(source.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(source.title, systemImage: "arrow.up.right.square")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(source.url.host() ?? source.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                if let snippet = source.snippet, !snippet.isEmpty {
                                    Text(snippet).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let date = source.date {
                                    Text(date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .accessibilityIdentifier("chat-web-sources")
                }
            }
            .navigationTitle(tool.renderedUI?.title ?? String(localized: "Web Sources"))
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        feedback += 1
                        dismiss()
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: feedback)
        }
        .summarySheetSize()
    }
}

/// In-progress status shown as a static capsule.
struct ChatStatusChip: View, Equatable {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
        .transition(.identity)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}

struct ChatReferenceCard: View {
    let reference: SummaryReference

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummaryOGImage(url: reference.ogImageUrl, title: reference.title, label: reference.siteName, authorized: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(reference.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack {
                    if let category = reference.category {
                        Text(category).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                    }
                    Spacer()
                    if let date = reference.viewedAt ?? reference.createdAt {
                        Text(SummaryDateFormatter.display(date)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 240)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary) }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        .transition(.identity)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}
