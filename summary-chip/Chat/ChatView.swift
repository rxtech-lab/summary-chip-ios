import AgentMarkdownUI
import AgentMessageListUI
import SummaryKit
import SwiftUI


/// The library-wide agent (Chat tab, or the trailing chat column on large screens), or —
/// with `summary` — a chat about one summary, presented as a sheet from its detail screen, or —
/// with `trip` — the trip agent, presented as a sheet from the trip's screen; it can edit the trip.
struct ChatView: View {
    let environment: AppEnvironment
    let summary: Summary?
    /// Shown as a column beside other content rather than as its own page or sheet.
    let isPanel: Bool
    private let onClose: (() -> Void)?
    @State private var voice = LiveVoiceModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatModel
    @State private var transcriptEntries: [ChatEntry]
    @State private var transcriptUpdateTask: Task<Void, Never>?
    @State private var isAtBottom = true
    @State private var selectedReference: ChatSummaryReference?
    @State private var referenceToOpen: Summary?
    @State private var contextDocument: Summary?
    @State private var inputBarHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toolDetail: ChatToolActivity?
    @State private var interactionFeedback = 0
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openLibraryItem) private var openLibraryItem

    init(environment: AppEnvironment, summary: Summary? = nil, trip: TripChat? = nil, miniAppID: String? = nil, isPanel: Bool = false, model: ChatModel? = nil, onTripUpdated: (() -> Void)? = nil, onGraphUpdated: (() -> Void)? = nil, onGraphSelection: ((GraphSelection?) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.environment = environment
        self.summary = summary
        self.isPanel = isPanel
        self.onClose = onClose
        let model = model ?? ChatModel(client: environment.chatClient, store: environment.chatStore, summaryID: summary?.id, trip: trip, miniAppID: miniAppID)
        if let onTripUpdated { model.onTripUpdated = onTripUpdated }
        if let onGraphUpdated { model.onGraphUpdated = onGraphUpdated }
        if let onGraphSelection { model.onGraphSelection = onGraphSelection }
        self._model = State(initialValue: model)
        self._transcriptEntries = State(initialValue: model.entries)
    }

    /// While running these show as a chip over the transcript instead of a card in it.

    private var trip: TripChat? { model.trip }
    /// A chat about one summary or trip, presented as a sheet over it.
    private var isSheet: Bool { summary != nil || trip != nil || model.miniAppID != nil || model.graph != nil }

    private var title: Text {
        if model.miniAppID != nil { return Text("Clip Builder") }
        if model.graph != nil { return Text("Graph Agent") }
        if let trip { return trip.isExpense ? Text("Add Expense with AI") : Text("Trip Agent") }
        return summary == nil ? Text("Chat") : Text("Ask About This")
    }

    private var placeholder: String {
        if model.graph != nil { return String(localized: "Ask, change or highlight the graph") }
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
            if voice.isActive {
                liveContent
            } else if model.entries.isEmpty {
                emptyState
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if isPanel && !voice.isActive {
                HStack {
                    Spacer()
                    Button {
                        model.newChat()
                        interactionFeedback += 1
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .help("New Chat")
                    .buttonStyle(.plain)
                    .platformGlassEffect(.regular.interactive(), in: Circle())
                    .disabled(model.entries.isEmpty || voice.isActive)

                }
                .padding()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
        }
        .onAppear { transcriptEntries = model.entries }
        .onChange(of: model.entries) { oldEntries, newEntries in
            updateTranscript(oldEntries: oldEntries, newEntries: newEntries)
        }
        .onChange(of: model.isStreaming) { _, isStreaming in
            if !isStreaming { flushTranscript() }
        }
        .onDisappear {
            voice.stop()
            transcriptUpdateTask?.cancel()
            transcriptUpdateTask = nil
        }
        // The composer floats over the transcript with no backing bar; its height
        // becomes the list's bottom inset so the last row still rests above it.
        .overlay(alignment: .bottom) {
            Group {
                if !voice.isActive { inputBar }
            }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard abs(height - inputBarHeight) > 0.5 else { return }
                    inputBarHeight = height
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { voice.stop() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: voice.isActive)
        .sensoryFeedback(.error, trigger: voice.error)
        .statusAlert("Couldn't Continue Voice Chat", message: voice.error) { voice.error = nil }
        .sheet(item: $toolDetail) { tool in
            ChatToolDetailSheet(tool: tool, environment: environment)
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
            guard let tool = tools?.last, ["renderUI", "searchWeb", "updateTrip", "updateGraph", "selectGraphElements"].contains(tool.toolName) else { return nil }
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
                if isSheet { closeChat() }
                environment.pendingTopUp = true
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Chatting uses points based on the AI's usage. Top up to keep chatting.")
        }
        .summarySearchToolbar(isEnabled: !isSheet && !isPanel)
        .toolbar {
            if isSheet && !isPanel && onClose == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { closeChat() }
                }
            }
            #if !os(visionOS)
            if !isSheet && !isPanel {
                ToolbarSpacer(.fixed, placement: .summaryTrailing)
            }
            #endif
            if !isPanel {
            ToolbarItem(placement: .summaryTrailing) {
                Button {
                    model.newChat()
                    interactionFeedback += 1
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(model.entries.isEmpty || voice.isActive)
            }
            }
        }
    }

    private func closeChat() {
        if let onClose {
            onClose()
        } else if !isPanel {
            dismiss()
        }
    }

    private func openSelectedTrip() {
        interactionFeedback += 1
        guard let summary = referenceToOpen, let openLibraryItem else { return }
        referenceToOpen = nil
        if isSheet {
            // Close the summary/trip chat as well before changing its underlying page.
            closeChat()
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
        .contentMargins(.top, isPanel ? headerHeight : 0, for: .scrollContent)
        .contentMargins(.bottom, inputBarHeight, for: .scrollContent)
#if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
#endif
    }

    private var transcript: some View {
        // Let the SDK follow the bottom until the user scrolls back into history.
        GeometryReader { geometry in
            // Constrain horizontal result strips to the transcript's width.
            let rowWidth = max(0, geometry.size.width - 32)
            MessageList(
                messages: transcriptEntries,
                isStreaming: model.isStreaming,
                scrollToBottomAnimated: !reduceMotion,
                bottomInset: inputBarHeight,
                isAtBottom: $isAtBottom
            ) { entry in
                ChatEntryView(entry: entry, openSummary: {
                    selectedReference = ChatSummaryReference(id: $0)
                    interactionFeedback += 1
                }, openTool: {
                    toolDetail = $0
                    interactionFeedback += 1
                }, runQuery: model.graph == nil ? nil : { query in
                    guard let graph = model.graph else { return }
                    let result = try await environment.api.queryGraph(id: graph.id, query: query)
                    let selection = GraphSelection(mode: .highlight, nodeIds: result.nodeIds, edgeIds: result.edgeIds, query: query)
                    try await environment.api.setGraphSelection(id: graph.id, selection: selection)
                    model.onGraphSelection?(selection)
                })
                    .equatable()
                    .id(entry.id)
                    .frame(width: rowWidth, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .padding(.top, isPanel && entry.id == transcriptEntries.first?.id ? headerHeight : 0)
                    // While streaming text grows a row, its cell resizes a beat later. Keep
                    // the row at its natural height and pinned to the cell's top so the
                    // cards above the text never shift or get squeezed meanwhile.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .transition(.identity)

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
        // still advances every 80 milliseconds instead of waiting until it goes quiet.
        guard transcriptUpdateTask == nil else { return }
        transcriptUpdateTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(80))
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

    private var contextDocumentID: String? {
        model.summaryID ?? model.trip?.id ?? model.graph?.id ?? model.miniAppID
    }

    private var contextDocumentTitle: String? {
        guard let id = contextDocumentID else { return nil }
        return environment.library.items.first(where: { $0.id == id })?.title
            ?? summary?.title ?? model.trip?.title
            ?? contextDocument?.title
    }

    private var contextIcon: String {
        if model.graph != nil { return "point.3.connected.trianglepath.dotted" }
        if model.trip != nil { return "map" }
        if model.miniAppID != nil { return "app.badge" }
        return "doc.text"
    }

    private var contextBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if contextDocumentID != nil {
                    Label {
                        Text(contextDocumentTitle ?? String(localized: "Current Document"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                    } icon: {
                        Image(systemName: contextIcon)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                    .accessibilityIdentifier("chat-context-document")
                } else {
                    Label("Chippy Library", systemImage: "books.vertical")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                        .accessibilityIdentifier("chat-context-library")
                }
                ForEach(model.graphElements) { element in
                    Button {
                        model.graphElements.removeAll { $0 == element }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: {
                                if case .node = element { return "circle.fill" }
                                return "line.diagonal"
                            }())
                            Text(model.graphElementLabel(element))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .leading)
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove " + model.graphElementLabel(element))
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: model.graphElements)
        .task(id: contextDocumentID) {
            contextDocument = nil
            guard let id = contextDocumentID, contextDocumentTitle == nil else { return }
            let document = try? await environment.api.summary(id: id)
            guard !Task.isCancelled, contextDocumentID == id else { return }
            contextDocument = document
        }
    }

    private var liveContent: some View {
        GeometryReader { geometry in
            // Keep controls within the viewport; allow scrolling only in compact windows.
            ScrollView {
                LiveVoiceControls(
                    responseHeight: min(160, max(80, geometry.size.height - 620)),
                    contentHeight: max(600, geometry.size.height),
                    voice: voice,
                    currentTool: model.entries.flatMap(\.tools).last { $0.id == voice.currentToolID },
                    openTool: {
                        toolDetail = $0
                        interactionFeedback += 1
                    }
                )
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            contextBar
            composer
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                // The glass capsule is the field's only outline; drop the platform border.
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .padding(.trailing, 38)
                .platformGlassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(alignment: .trailing) {
                    Button {
                        inputFocused = false
                        voice.start(api: environment.api, chat: model)
                    } label: {
                        Image(systemName: "mic.fill").frame(width: 36, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isStreaming)
                    .accessibilityLabel("Start voice chat")
                    .accessibilityIdentifier("chat-voice-start")
                }
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

private struct ChatEntryView: View, Equatable {
    let entry: ChatEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openSummary: (String) -> Void
    let openTool: (ChatToolActivity) -> Void
    var runQuery: ((String) async throws -> Void)? = nil

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
                ForEach(entry.displayParts) { part in
                    if let toolID = part.toolID,
                       let tool = entry.tools.first(where: { $0.id == toolID }) {
                        ChatToolCallCard(tool: tool, openSummary: openSummary, openTool: openTool, runQuery: runQuery)
                            .equatable()
                            .transaction { transaction in
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                    } else if part.toolID == nil {
                        MarkdownView(
                            text: part.text,
                            showsTrailingCursor: entry.isStreaming && part.id == entry.displayParts.last?.id,
                            fadeNewText: !reduceMotion
                        )
                        .textSelection(.enabled)
                    }
                }
                if let usage = entry.usage {
                    Text("Input \(ChatTokenUsage.formatted(usage.input)) · Output \(ChatTokenUsage.formatted(usage.output)) · Cached \(ChatTokenUsage.formatted(usage.cached))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("chat-token-usage")
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
