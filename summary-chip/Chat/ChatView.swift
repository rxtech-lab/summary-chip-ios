import AgentMarkdownUI
import AgentMessageListUI
import SummaryKit
import SwiftUI

struct ChatSummaryRoute: Hashable { let id: String }

/// The library-wide agent (Chat tab), or — with `summary` — a chat about one summary,
/// presented as a sheet from its detail screen.
struct ChatView: View {
    let environment: AppEnvironment
    let summary: Summary?
    @State private var model: ChatModel
    @State private var path: [ChatSummaryRoute] = []
    @State private var inputBarHeight: CGFloat = 0
    @State private var shouldScrollToBottom = false
    @State private var isAtBottom = true
    @State private var scrollRequest: Task<Void, Never>?
    @State private var followRequest: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, summary: Summary? = nil) {
        self.environment = environment
        self.summary = summary
        self._model = State(initialValue: ChatModel(client: environment.chatClient, store: environment.chatStore, summaryID: summary?.id))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.entries.isEmpty {
                    emptyState
                } else {
                    transcript
                }
            }
            // The input floats over the transcript; `MessageList` gets its height as
            // `bottomInset` so the last row still rests just above it.
            .overlay(alignment: .bottom) {
                inputBar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard abs(height - inputBarHeight) > 0.5 else { return }
                        inputBarHeight = height
                    }
            }
            .sensoryFeedback(trigger: model.isStreaming) { _, isStreaming in
                if isStreaming { return .impact(weight: .light) }
                return model.entries.last?.errorText == nil ? .impact(flexibility: .soft) : .error
            }
            .navigationTitle(summary == nil ? "Chat" : "Ask About This")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ChatSummaryRoute.self) { route in
                // Already inside a summary chat sheet: don't offer another one on top.
                SummaryLoaderView(environment: environment, id: route.id, allowsChat: summary == nil)
            }
            .toolbar {
                if summary != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.newChat()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .disabled(model.entries.isEmpty)
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)
                VStack(spacing: 6) {
                    if let summary {
                        Text(summary.title)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Text("Ask anything — answers come from the original content.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Ask about your summaries").font(.title2.weight(.bold))
                        Text("Search, compare and recall everything you've saved or viewed.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                VStack(spacing: 10) {
                    ForEach(model.suggestions, id: \.self) { suggestion in
                        Button {
                            model.send(suggestion)
                        } label: {
                            HStack {
                                Text(suggestion).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "arrow.up.circle")
                            }
                            .padding()
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .safeAreaPadding(.bottom, inputBarHeight)
        .scrollDismissesKeyboard(.interactively)
    }

    private var transcript: some View {
        // `isStreaming` stays false: `MessageList` would otherwise snap to the bottom on
        // every layout pass (every token). `followStream()` scrolls on a debounce instead.
        // `.onSend` still pins each sent question to the top while its answer fills in below.
        MessageList(
            messages: model.entries,
            isStreaming: false,
            shouldScrollToBottom: shouldScrollToBottom,
            userMessagePinning: .onSend,
            bottomInset: inputBarHeight,
            isAtBottom: $isAtBottom
        ) { entry in
            ChatEntryView(entry: entry) { path.append(ChatSummaryRoute(id: $0)) }
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .onChange(of: model.entries.count) { old, new in
            if new > old { pulseScrollToBottom() }
        }
        .onChange(of: model.entries.last) { followStream() }
    }

    /// Coalesces streamed updates into at most one scroll per interval, and only while
    /// the reader is still at the bottom, so scrolling up to read isn't interrupted.
    private func followStream() {
        guard followRequest == nil, isAtBottom else { return }
        followRequest = Task {
            try? await Task.sleep(for: .milliseconds(300))
            followRequest = nil
            guard !Task.isCancelled, isAtBottom else { return }
            pulseScrollToBottom()
        }
    }

    /// `MessageList` scrolls on the false→true edge of `shouldScrollToBottom`, so each
    /// send has to pulse it rather than just set it.
    private func pulseScrollToBottom() {
        scrollRequest?.cancel()
        shouldScrollToBottom = false
        scrollRequest = Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            shouldScrollToBottom = true
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(summary == nil ? "Ask about your summaries" : "Ask about this summary", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onSubmit { model.send() }
                .submitLabel(.send)
                .accessibilityIdentifier("chat-input")
            if model.isStreaming {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 34))
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct ChatEntryView: View {
    let entry: ChatEntry
    let openSummary: (String) -> Void

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(entry.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entry.tools) { tool in
                    ChatToolView(tool: tool, openSummary: openSummary)
                }
                if !entry.text.isEmpty {
                    MarkdownView(text: entry.text, fadeNewText: entry.isStreaming)
                        .textSelection(.enabled)
                }
                if entry.isStreaming {
                    ChatStatusChip(text: "Thinking…")
                }
                if let error = entry.errorText {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChatToolView: View {
    let tool: ChatToolActivity
    let openSummary: (String) -> Void

    var body: some View {
        if tool.isRunning {
            ChatStatusChip(text: tool.label.isEmpty ? "Searching…" : tool.label)
        } else if !tool.references.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(tool.references) { reference in
                        // Rows live in a UICollectionView cell, outside the NavigationStack's
                        // reach, so navigation goes through the view's path instead of a link.
                        Button {
                            openSummary(reference.id)
                        } label: {
                            ChatReferenceCard(reference: reference)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }
}

/// In-progress status shown as a pulsing capsule rather than a spinner.
private struct ChatStatusChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct ChatReferenceCard: View {
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
    }
}
