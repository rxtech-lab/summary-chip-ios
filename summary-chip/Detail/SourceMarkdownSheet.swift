import AgentMarkdownUI
import SummaryKit
import SwiftUI

/// The summary's source, kept as Markdown on the server, rendered for reading.
struct SourceMarkdownSheet: View {
    let api: SummaryAPIClient
    let summary: Summary
    @Environment(\.dismiss) private var dismiss
    @State private var markdown: String?
    @State private var errorMessage: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let markdown {
                    ScrollView {
                        MarkdownView(text: markdown, baseURL: summary.sourceUrl, style: Self.documentStyle)
                            .textSelection(.enabled)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .padding(.bottom, 40)
                            .frame(maxWidth: 700, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("source-markdown")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Source unavailable", systemImage: "doc.plaintext")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { attempt += 1 }
                    }
                } else {
                    ProgressView("Loading source…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(summary.sourceTitle ?? summary.title)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let markdown {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: markdown, preview: SharePreview(summary.sourceTitle ?? summary.title)) {
                            Label("Share Source", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .summarySheetSize()
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .task(id: attempt) { await load() }
    }

    /// Reading typography: a larger body with airy lines and paragraph spacing, like a printed article.
    private static let documentStyle = MarkdownStyle(
        bodyFontSize: documentFontSize,
        lineSpacing: 6,
        blockSpacing: 16,
        cornerRadius: 10
    )

    #if os(macOS)
    private static let documentFontSize: CGFloat = 15
    #else
    private static let documentFontSize: CGFloat = 17
    #endif

    private func load() async {
        errorMessage = nil
        do {
            markdown = try await api.sourceMarkdown(id: summary.id)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
