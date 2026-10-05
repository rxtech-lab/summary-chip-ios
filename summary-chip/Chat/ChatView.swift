import AgentMarkdownUI
import AgentMessageListUI
import SummaryKit
import SwiftUI

struct ChatSummaryRoute: Hashable { let id: String }

/// The library-wide agent (Chat tab, or the trailing chat column on large screens), or —
/// with `summary` — a chat about one summary, presented as a sheet from its detail screen, or —
/// with `trip` — the trip agent, presented as a sheet from the trip's screen; it can edit the trip.
struct ChatView: View {
    let environment: AppEnvironment
    let summary: Summary?
    /// Shown as a column beside other content rather than as its own page or sheet.
    let isPanel: Bool
    @State private var model: ChatModel
    @State private var path: [ChatSummaryRoute] = []
    @State private var isAtBottom = true
    @State private var inputBarHeight: CGFloat = 0
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, summary: Summary? = nil, trip: TripChat? = nil, isPanel: Bool = false, model: ChatModel? = nil, onTripUpdated: (() -> Void)? = nil) {
        self.environment = environment
        self.summary = summary
        self.isPanel = isPanel
        let model = model ?? ChatModel(client: environment.chatClient, store: environment.chatStore, summaryID: summary?.id, trip: trip)
        model.onTripUpdated = onTripUpdated
        self._model = State(initialValue: model)
    }

    private var trip: TripChat? { model.trip }
    /// A chat about one summary or trip, presented as a sheet over it.
    private var isSheet: Bool { summary != nil || trip != nil }

    private var title: Text {
        if let trip { return trip.isExpense ? Text("Add Expense with AI") : Text("Trip Agent") }
        return summary == nil ? Text("Chat") : Text("Ask About This")
    }

    private var placeholder: String {
        if let trip {
            return trip.isExpense ? String(localized: "Paste a receipt or describe a cost") : String(localized: "Ask, or paste a booking or link")
        }
        return summary == nil ? String(localized: "Ask about your summaries") : String(localized: "Ask about this summary")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The composer floats over the transcript with no backing bar; its height
            // becomes the list's bottom inset so the last row still rests above it.
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
            .onChange(of: model.isStreaming) { _, isStreaming in
                // Each answer spends points; keep the balance shown elsewhere current.
                guard !isStreaming else { return }
                Task { await environment.credits.refresh(api: environment.api, broker: environment.tokenBroker) }
            }
            .alert("Not Enough Points", isPresented: $model.needsTopUp) {
                Button("Top Up") {
                    // The top-up sheet is presented from the root, so close this chat sheet first.
                    if isSheet { dismiss() }
                    environment.pendingTopUp = true
                }
                Button("Later", role: .cancel) {}
            } message: {
                Text("Chatting uses points based on the AI's usage. Top up to keep chatting.")
            }
            .navigationTitle(title)
            .summaryInlineNavigationTitle()
            .summarySearchToolbar(isEnabled: !isSheet && !isPanel)
            .navigationDestination(for: ChatSummaryRoute.self) { route in
                // Already inside a summary chat sheet: don't offer another one on top.
                SummaryLoaderView(environment: environment, id: route.id, allowsChat: !isSheet)
            }
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                if !isSheet && !isPanel {
                    ToolbarSpacer(.fixed, placement: .summaryTrailing)
                }
                ToolbarItem(placement: .summaryTrailing) {
                    Button {
                        model.newChat()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .disabled(model.entries.isEmpty)
                }
            }
        }
        .modifier(SheetSizeUnlessPanel(isPanel: isPanel))
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: trip == nil ? "sparkles" : trip?.isExpense == true ? "creditcard" : "suitcase")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)
                VStack(spacing: 6) {
                    if let trip {
                        Text(trip.title)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Text(trip.isExpense
                             ? "Paste a receipt or booking, or describe what you paid — the agent adds it to the trip's costs."
                             : "Ask about the trip, or paste a booking, timetable or link — the agent updates the trip for you.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else if let summary {
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
        .contentMargins(.bottom, inputBarHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
    }

    private var transcript: some View {
        // The native list pins the sent question, follows growing row heights, and
        // releases that anchor when the reader scrolls away. Extra scroll pulses
        // on token updates compete with its layout and reset the reader's position.
        GeometryReader { geometry in
            // AppKit hosts each row separately. Give it the viewport's width so a
            // horizontal result strip cannot determine the width of the whole row.
            let rowWidth = max(0, geometry.size.width - 32)
            MessageList(
                messages: model.entries,
                isStreaming: model.isStreaming,
                bottomInset: inputBarHeight,
                isAtBottom: $isAtBottom
            ) { entry in
                ChatEntryView(entry: entry) { path.append(ChatSummaryRoute(id: $0)) }
                    .frame(width: rowWidth, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                // The glass capsule is the field's only outline; drop the platform border.
                .textFieldStyle(.plain)
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
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("Stop")
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct SheetSizeUnlessPanel: ViewModifier {
    let isPanel: Bool

    func body(content: Content) -> some View {
        if isPanel {
            content
        } else {
            content.summarySheetSize()
        }
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
                    ChatToolCallCard(tool: tool, openSummary: openSummary)
                }
                if !entry.text.isEmpty {
                    // Keep the live parse path, but render each delta without a
                    // fade transaction that can animate existing blocks and sizing.
                    MarkdownView(text: entry.text, showsTrailingCursor: entry.isStreaming, fadeNewText: false)
                        .textSelection(.enabled)
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                }
                // A running tool card already pulses; don't stack a second status under it.
                if entry.isStreaming, !entry.tools.contains(where: \.isRunning) {
                    ChatStatusChip(text: String(localized: "Thinking…"))
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

/// One agent tool call as a card: what the agent did and with which query, its state, and the
/// summaries it found (tappable). Running calls pulse instead of showing a spinner.
private struct ChatToolCallCard: View {
    let tool: ChatToolActivity
    let openSummary: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !tool.references.isEmpty {
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
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tool.errorText == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.12), in: Circle())
                .symbolEffect(.pulse, options: .repeating, isActive: tool.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let status {
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var isSearch: Bool { tool.toolName == "searchSummaries" }

    private var symbol: String {
        if tool.errorText != nil { return "exclamationmark.magnifyingglass" }
        switch tool.toolName {
        case "searchSummaries": return tool.isSemantic == true ? "sparkle.magnifyingglass" : "magnifyingglass"
        case "getSummary": return "doc.text.magnifyingglass"
        case "grepLocalFile": return "text.magnifyingglass"
        case "readLocalFile": return "doc.plaintext"
        case "readWebPage": return "globe"
        case "updateTrip": return "suitcase"
        default: return "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch tool.toolName {
        case "searchSummaries":
            if tool.isRunning { return String(localized: "Searching your library…") }
            return tool.finished == true ? String(localized: "Searched your library") : String(localized: "Search stopped")
        case "getSummary":
            if tool.isRunning { return String(localized: "Reading summary…") }
            return tool.finished == true ? String(localized: "Read summary") : String(localized: "Reading stopped")
        case "grepLocalFile":
            if tool.isRunning { return String(localized: "Searching the file…") }
            return tool.finished == true ? String(localized: "Searched the file") : String(localized: "Search stopped")
        case "readLocalFile":
            if tool.isRunning { return String(localized: "Reading the file…") }
            return tool.finished == true ? String(localized: "Read the file") : String(localized: "Reading stopped")
        case "readWebPage":
            if tool.isRunning { return String(localized: "Reading the page…") }
            return tool.finished == true ? String(localized: "Read the page") : String(localized: "Reading stopped")
        case "updateTrip":
            if tool.isRunning { return String(localized: "Updating the trip…") }
            if tool.errorText != nil { return String(localized: "Changes needed fixing") }
            return tool.finished == true ? String(localized: "Updated the trip") : String(localized: "Update stopped")
        default:
            if tool.isRunning { return tool.label.isEmpty ? String(localized: "Working…") : tool.label }
            return tool.toolName.isEmpty ? String(localized: "Used a tool") : String(localized: "Used \(tool.toolName)")
        }
    }

    private var detail: String? {
        if let error = tool.errorText { return error }
        if tool.toolName == "getSummary" { return tool.references.first?.title }
        return tool.detail
    }

    private var status: String? {
        if let status = tool.status { return status }
        guard isSearch, tool.finished == true else { return nil }
        let count = tool.references.count
        if tool.isSemantic == true {
            return count == 0 ? String(localized: "No matches · by meaning")
                : count == 1 ? String(localized: "1 result · by meaning")
                : String(localized: "\(count) results · by meaning")
        }
        return count == 0 ? String(localized: "No matches") : count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")
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
