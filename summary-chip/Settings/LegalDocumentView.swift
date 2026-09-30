import SummaryKit
import SwiftUI

struct LegalDocumentView: View {
    let document: LegalDocument
    let baseURL: URL

    @State private var state: LoadingState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading \(document.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let markdown):
                ScrollView {
                    MarkdownDocument(markdown: markdown)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .refreshable { await load(showingPlaceholder: false) }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to Load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: document) { await load() }
        .accessibilityIdentifier("legal-document-view")
    }

    /// Pull-to-refresh keeps the loaded document on screen: swapping to `.loading` would tear down
    /// the scroll view that owns the refresh and cancel the reload.
    private func load(showingPlaceholder: Bool = true) async {
        if showingPlaceholder { state = .loading }
        do {
            let markdown = try await document.load(baseURL: baseURL)
            guard !Task.isCancelled else { return }
            state = .loaded(markdown)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private enum LoadingState {
        case loading
        case loaded(String)
        case failed(String)
    }
}

/// Renders the headings, bullet lists and paragraphs the legal documents use; inline styling
/// (bold, italic, links) goes through `AttributedString`'s own markdown parser.
private struct MarkdownDocument: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(level: level, text: line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level == 1 ? .title.weight(.bold) : .title3.weight(.semibold))
                        .padding(.top, level == 1 ? 0 : 8)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(Self.inline(text))
                    }
                case .paragraph(let text):
                    Text(Self.inline(text))
                }
            }
        }
        .textSelection(.enabled)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }
}
