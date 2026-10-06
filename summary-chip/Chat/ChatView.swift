import AgentMarkdownUI
import AgentMessageListUI
import SummaryKit
import SwiftUI

private struct ChatSummaryReference: Identifiable { let id: String }

/// The library-wide agent (Chat tab, or the trailing chat column on large screens), or —
/// with `summary` — a chat about one summary, presented as a sheet from its detail screen, or —
/// with `trip` — the trip agent, presented as a sheet from the trip's screen; it can edit the trip.
struct ChatView: View {
    let environment: AppEnvironment
    let summary: Summary?
    /// Shown as a column beside other content rather than as its own page or sheet.
    let isPanel: Bool
    @State private var model: ChatModel
    @State private var transcriptEntries: [ChatEntry]
    @State private var transcriptUpdateTask: Task<Void, Never>?
    @State private var isAtBottom = true
    @State private var selectedReference: ChatSummaryReference?
    @State private var referenceToOpen: Summary?
    @State private var inputBarHeight: CGFloat = 0
    @State private var toolDetail: ChatToolActivity?
    @State private var interactionFeedback = 0
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openLibraryItem) private var openLibraryItem

    init(environment: AppEnvironment, summary: Summary? = nil, trip: TripChat? = nil, isPanel: Bool = false, model: ChatModel? = nil, onTripUpdated: (() -> Void)? = nil) {
        self.environment = environment
        self.summary = summary
        self.isPanel = isPanel
        let model = model ?? ChatModel(client: environment.chatClient, store: environment.chatStore, summaryID: summary?.id, trip: trip)
        model.onTripUpdated = onTripUpdated
        self._model = State(initialValue: model)
        self._transcriptEntries = State(initialValue: model.entries)
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
        Group {
            if isPanel {
                // The inspector already belongs to the detail column's navigation container.
                chatContent
            } else {
                NavigationStack {
                    chatContent
                        .navigationTitle(title)
                        .summaryInlineNavigationTitle()
                }
            }
        }
        .modifier(SheetSizeUnlessPanel(isPanel: isPanel))
    }

    private var chatContent: some View {
        Group {
            if model.entries.isEmpty {
                emptyState
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { transcriptEntries = model.entries }
        .onChange(of: model.entries) { oldEntries, newEntries in
            updateTranscript(oldEntries: oldEntries, newEntries: newEntries)
        }
        .onChange(of: model.isStreaming) { _, isStreaming in
            if !isStreaming { flushTranscript() }
        }
        .onDisappear {
            transcriptUpdateTask?.cancel()
            transcriptUpdateTask = nil
        }
        // The composer floats over the transcript with no backing bar; its height
        // becomes the list's bottom inset so the last row still rests above it.
        .overlay(alignment: .bottom) {
            inputBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard abs(height - inputBarHeight) > 0.5 else { return }
                    inputBarHeight = height
                }
        }
        .overlay(alignment: .top) {
            if let activity = model.entries.last?.tools.last(where: { $0.isRunning && ["renderUI", "readWebPage", "updateTrip"].contains($0.toolName) }) {
                ChatStatusChip(text: activity.label)
                    .equatable()
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $toolDetail) { tool in
            ChatToolDetailSheet(tool: tool)
        }
        .sheet(item: $selectedReference, onDismiss: openSelectedTrip) { reference in
            ChatSummarySheet(
                environment: environment,
                reference: reference,
                allowsChat: !isSheet,
                onOpenTrip: openLibraryItem == nil ? nil : { summary in
                    referenceToOpen = summary
                    selectedReference = nil
                }
            )
        }
        .sensoryFeedback(.selection, trigger: interactionFeedback)
        .sensoryFeedback(trigger: model.entries.last?.tools.filter { $0.finished == true }) { _, tools in
            guard let tool = tools?.last, ["renderUI", "searchWeb", "updateTrip"].contains(tool.toolName) else { return nil }
            return tool.errorText == nil ? .success : .error
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
        .summarySearchToolbar(isEnabled: !isSheet && !isPanel)
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
                    interactionFeedback += 1
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(model.entries.isEmpty)
            }
        }
    }

    private func openSelectedTrip() {
        interactionFeedback += 1
        guard let summary = referenceToOpen, let openLibraryItem else { return }
        referenceToOpen = nil
        if isSheet {
            // Close the summary/trip chat as well before changing its underlying page.
            dismiss()
            Task {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                openLibraryItem(summary)
            }
        } else {
            openLibraryItem(summary)
        }
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
                        Text("Search your summaries and the web, and explore answers in tables and charts.")
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
        // Let the SDK pin the latest question and manage native scrolling.
        GeometryReader { geometry in
            // Constrain horizontal result strips to the transcript's width.
            let rowWidth = max(0, geometry.size.width - 32)
            MessageList(
                messages: transcriptEntries,
                isStreaming: model.isStreaming,
                scrollToBottomAnimated: false,
                bottomInset: inputBarHeight,
                isAtBottom: $isAtBottom
            ) { entry in
                ChatEntryView(entry: entry, openSummary: {
                    selectedReference = ChatSummaryReference(id: $0)
                    interactionFeedback += 1
                }, openTool: {
                    toolDetail = $0
                    interactionFeedback += 1
                })
                    .equatable()
                    .id(entry.id)
                    .frame(width: rowWidth, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    // While streaming text grows a row, its cell resizes a beat later. Keep
                    // the row at its natural height and pinned to the cell's top so the
                    // cards above the text never shift or get squeezed meanwhile.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .transition(.identity)
                    .transaction {
                        $0.animation = nil
                        $0.disablesAnimations = true
                    }
            }
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }

    private func updateTranscript(oldEntries: [ChatEntry], newEntries: [ChatEntry]) {
        // A new turn, cleared chat, or settled reply should appear immediately.
        guard model.isStreaming, oldEntries.map(\.id) == newEntries.map(\.id) else {
            flushTranscript()
            return
        }
        // Keep the pending deadline while tokens arrive so a continuous stream
        // still advances every half second instead of waiting until it goes quiet.
        guard transcriptUpdateTask == nil else { return }
        transcriptUpdateTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
            } catch {
                return
            }
            transcriptEntries = model.entries
            transcriptUpdateTask = nil
        }
    }

    private func flushTranscript() {
        transcriptUpdateTask?.cancel()
        transcriptUpdateTask = nil
        transcriptEntries = model.entries
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
                // The keyboard's return key is labelled Send too.
                .accessibilityIdentifier("chat-send")
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

/// References open in a separate presentation, with navigation independent of the chat's host.
private struct ChatSummarySheet: View {
    let environment: AppEnvironment
    let reference: ChatSummaryReference
    let allowsChat: Bool
    let onOpenTrip: ((Summary) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SummaryLoaderView(environment: environment, id: reference.id, allowsChat: allowsChat, onOpenTrip: onOpenTrip)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .summarySheetSize()
    }
}

private struct ChatEntryView: View, Equatable {
    let entry: ChatEntry
    let openSummary: (String) -> Void
    let openTool: (ChatToolActivity) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry
    }

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
                ForEach(entry.tools.filter { !$0.isRunning || !["renderUI", "readWebPage", "updateTrip"].contains($0.toolName) }) { tool in
                    ChatToolCallCard(tool: tool, openSummary: openSummary, openTool: openTool)
                        .equatable()
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                }
                if entry.isStreaming || !entry.text.isEmpty {
                    // Keep the live renderer mounted and show each chunk immediately.
                    MarkdownView(
                        text: entry.text,
                        showsTrailingCursor: entry.isStreaming,
                        fadeNewText: false
                    )
                        .textSelection(.enabled)
                }
                // A running tool card already shows its status.
                if entry.isStreaming, !entry.tools.contains(where: \.isRunning) {
                    ChatStatusChip(text: String(localized: "Thinking…"))
                        .equatable()
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
/// summaries it found (tappable). Running calls show a static status.
private struct ChatToolCallCard: View, Equatable {
    let tool: ChatToolActivity
    let openSummary: (String) -> Void
    let openTool: (ChatToolActivity) -> Void

    // Text deltas change the parent entry, but not a completed tool's content.
    // Ignore rebuilt navigation closures so its images and effects stay mounted.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tool == rhs.tool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let ui = tool.renderedUI {
                Button {
                    openTool(tool)
                } label: {
                    HStack {
                        Label(ui.title, systemImage: "rectangle.3.group")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("chat-rendered-ui-\(tool.id)")
            } else if let sources = tool.webReferences, !sources.isEmpty {
                Button {
                    openTool(tool)
                } label: {
                    Label("View Sources (\(sources.count))", systemImage: "globe")
                        .font(.subheadline.weight(.semibold))
                        .padding(10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("chat-web-sources-\(tool.id)")
            }
            if !tool.references.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(tool.references) { reference in
                            // Open each reference in its dedicated detail sheet.
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

    private var isSearch: Bool { ["searchSummaries", "listTrips"].contains(tool.toolName) }

    private var symbol: String {
        if tool.errorText != nil { return "exclamationmark.magnifyingglass" }
        switch tool.toolName {
        case "searchWeb": return "globe"
        case "renderUI": return "rectangle.3.group"
        case "searchSummaries": return tool.isSemantic == true ? "sparkle.magnifyingglass" : "magnifyingglass"
        case "getSummary": return "doc.text.magnifyingglass"
        case "listTrips", "getTrip": return "suitcase"
        case "grepLocalFile": return "text.magnifyingglass"
        case "readLocalFile": return "doc.plaintext"
        case "readWebPage": return "globe"
        case "updateTrip": return "suitcase"
        default: return "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch tool.toolName {
        case "searchWeb":
            if tool.isRunning { return String(localized: "Searching the web…") }
            if tool.errorText != nil { return String(localized: "Web search unavailable") }
            return tool.finished == true ? String(localized: "Searched the web") : String(localized: "Search stopped")
        case "renderUI":
            if tool.isRunning { return String(localized: "Creating a view…") }
            if tool.errorText != nil { return String(localized: "View needs correction") }
            return tool.renderedUI != nil ? String(localized: "View ready") : String(localized: "View stopped")
        case "searchSummaries":
            if tool.isRunning { return String(localized: "Searching your library…") }
            return tool.finished == true ? String(localized: "Searched your library") : String(localized: "Search stopped")
        case "getSummary":
            if tool.isRunning { return String(localized: "Reading summary…") }
            return tool.finished == true ? String(localized: "Read summary") : String(localized: "Reading stopped")
        case "listTrips":
            if tool.isRunning { return String(localized: "Finding your trips…") }
            return tool.finished == true ? String(localized: "Listed your trips") : String(localized: "Search stopped")
        case "getTrip":
            if tool.isRunning { return String(localized: "Reading the trip…") }
            return tool.finished == true ? String(localized: "Read the trip") : String(localized: "Reading stopped")
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
        if ["getSummary", "getTrip"].contains(tool.toolName) { return tool.references.first?.title }
        return tool.detail
    }

    private var status: String? {
        if tool.toolName == "searchWeb", tool.finished == true, tool.errorText == nil {
            let count = tool.webReferences?.count ?? 0
            return count == 0 ? String(localized: "No web results") : String(localized: "\(count) web sources")
        }
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

/// JSON views and web research each have a dedicated sheet instead of expanding the transcript.
private struct ChatToolDetailSheet: View {
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
private struct ChatStatusChip: View, Equatable {
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
        .transition(.identity)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}
