import AgentMarkdownUI
import AgentMessageListUI
import LocalAgentKit
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers


/// The library-wide agent (Chat tab, or the trailing chat column on large screens), or —
/// with `summary` — a chat about one summary, presented as a sheet from its detail screen, or —
/// with `trip` — the trip agent, presented as a sheet from the trip's screen; it can edit the trip.
struct ChatView: View {
    let environment: AppEnvironment
    let summary: Summary?
    /// Shown as a column beside other content rather than as its own page or sheet.
    let isPanel: Bool
    private let onClose: (() -> Void)?
    private let onFocus: (() -> Void)?
    @State private var voice = LiveVoiceModel()
    @AppStorage(LiveVoiceSettings.engineKey) private var savedVoiceEngine = LiveVoiceEngine.chippy.rawValue
    @AppStorage(LiveVoiceSettings.languageKey) private var savedVoiceLanguage = ""
    #if os(macOS)
    @AppStorage(ChatAgentSelection.providerKey) private var savedChatProvider = ChatAgentSelection.cloud
    #endif
    @State private var showsVoiceEngines = false
    @State private var showsAIModels = false
    @State private var showsSubscription = false
    @State private var showsFilePicker = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatModel
    @State private var transcriptEntries: [ChatEntry]
    @State private var transcriptUpdateTask: Task<Void, Never>?
    @State private var isAtBottom = true
    @State private var selectedReference: ChatSummaryReference?
    @State private var referenceToOpen: Summary?
    @State private var inputBarHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toolDetail: ChatToolActivity?
    @State private var interactionFeedback = 0
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openLibraryItem) private var openLibraryItem

    init(environment: AppEnvironment, summary: Summary? = nil, trip: TripChat? = nil, miniAppID: String? = nil, resumeTarget: ResumeTarget? = nil, isPanel: Bool = false, model: ChatModel? = nil, onTripUpdated: (() -> Void)? = nil, onGraphUpdated: (() -> Void)? = nil, onGraphSelection: ((GraphSelection?) -> Void)? = nil, onClose: (() -> Void)? = nil, onFocus: (() -> Void)? = nil) {
        self.environment = environment
        self.summary = summary
        self.isPanel = isPanel
        self.onClose = onClose
        self.onFocus = onFocus
        let model = model ?? ChatModel(client: environment.chatClient, store: environment.chatStore, summaryID: summary?.id, trip: trip, miniAppID: miniAppID, resumeTarget: resumeTarget)
        if let onTripUpdated { model.onTripUpdated = onTripUpdated }
        if let onGraphUpdated { model.onGraphUpdated = onGraphUpdated }
        if let onGraphSelection { model.onGraphSelection = onGraphSelection }
        self._model = State(initialValue: model)
        self._transcriptEntries = State(initialValue: model.entries)
    }

    /// While running these show as a chip over the transcript instead of a card in it.

    private var trip: TripChat? { model.trip }
    /// A chat about one summary or trip, presented as a sheet over it.
    private var isSheet: Bool { summary != nil || trip != nil || model.miniAppID != nil || model.graph != nil || model.resumeTarget != nil }

    private var title: Text {
        if let target = model.resumeTarget { return Text("Résumé · \(SummaryLanguage.displayName(for: target.language))") }
        if model.miniAppID != nil { return Text("Clip Builder") }
        if model.graph != nil { return Text("Graph Agent") }
        if let trip { return trip.isExpense ? Text("Add Expense with AI") : Text("Trip Agent") }
        return summary == nil ? Text("Chat") : Text("Ask About This")
    }

    private var placeholder: String {
        if model.resumeTarget != nil { return String(localized: "Ask about this résumé") }
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
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            if isPanel, onClose != nil {
                Button {
                    interactionFeedback += 1
                    closeChat()
                } label: {
                    Label("Close Chat", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .platformGlassEffect(.regular.interactive(), in: Circle())
                .accessibilityIdentifier("close-chat-panel")
                .padding(10)
            }
        }
        #endif
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
                            #if os(iOS)
                            .frame(width: 44, height: 44)
                            #else
                            .frame(width: 32, height: 32)
                            #endif
                            .contentShape(Circle())
                    }
                    .help("New Chat")
                    .buttonStyle(.plain)
                    .platformGlassEffect(.regular.interactive(), in: Circle())
                    .disabled(!canStartNewChat)

                }
                #if os(iOS)
                .padding(10)
                #else
                .padding()
                #endif
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
        }
        .onAppear { transcriptEntries = model.entries }
        .onChange(of: inputFocused) { _, focused in
            if focused { onFocus?() }
        }
        .onChange(of: model.entries) { oldEntries, newEntries in
            updateTranscript(oldEntries: oldEntries, newEntries: newEntries)
        }
        .onChange(of: model.isStreaming) { _, isStreaming in
            if !isStreaming { flushTranscript() }
        }
        .onChange(of: voice.isActive) { _, active in model.isResumeVoiceActive = active && model.resumeTarget != nil }
        .onDisappear {
            model.isResumeVoiceActive = false
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
        .modifier(ChatFileImporter(files: model.files, isPresented: $showsFilePicker))
        .sheet(isPresented: $showsAIModels) { ChatAgentSheet(environment: environment) }
        .sheet(isPresented: $showsSubscription) { FlowcySubscriptionView(environment: environment, isSheet: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { voice.stop() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: voice.isActive)
        .sensoryFeedback(.error, trigger: voice.error)
        .statusAlert("Couldn't Continue Voice Chat", message: voice.error) { voice.error = nil }
        #if os(macOS)
        .sheet(isPresented: $showsVoiceEngines) { LiveVoiceEngineSheet() }
        .onChange(of: voice.needsLocalSetup) { _, needsSetup in
            guard needsSetup else { return }
            voice.needsLocalSetup = false
            showsVoiceEngines = true
        }
        #endif
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
                    .disabled(!canStartNewChat)
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
                if requiresSubscriptionForChat {
                    VStack(spacing: 12) {
                        #if os(macOS)
                        Text("Subscribe to Flowcy Plus for cloud AI chat, or switch to a local agent in AI Models.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #else
                        Text("Subscribe to Flowcy Plus to chat with AI about your library.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #endif
                        Button("Subscribe to Flowcy Plus") {
                            interactionFeedback += 1
                            showsSubscription = true
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("chat-subscribe-button")
                    }
                } else {
                VStack(spacing: 10) {
                    ForEach(model.suggestions, id: \.self) { suggestion in
                        Button {
                            sendMessage(suggestion)
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
                        .disabled(model.files.uploadProgress != nil)
                    }
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

}

// MARK: - Voice and message composer

private extension ChatView {
    var canSend: Bool {
        model.files.uploadProgress == nil && (!model.files.attachments.isEmpty || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var canStartNewChat: Bool {
        !voice.isActive && (!model.entries.isEmpty || !model.files.attachments.isEmpty || model.files.uploadProgress != nil)
    }

    var liveContent: some View {
        GeometryReader { geometry in
            // Keep controls within the viewport; allow scrolling only in compact windows.
            ScrollView {
                LiveVoiceControls(
                    responseHeight: min(160, max(80, geometry.size.height - 620)),
                    contentHeight: max(600, geometry.size.height),
                    voice: voice,
                    currentTool: model.entries.flatMap(\.tools).last { $0.id == voice.currentToolID },
                    tools: model.entries.flatMap(\.tools).filter { !voice.previousToolIDs.contains($0.id) },
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

    var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatContextBar(environment: environment, model: model, summary: summary)
            composer
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Only the Mac can run local agents, so iOS and visionOS always use the cloud voice.
    var voiceEngine: LiveVoiceEngine {
        #if os(macOS)
        LiveVoiceEngine(saved: savedVoiceEngine)
        #else
        .chippy
        #endif
    }

    var usesCloudChat: Bool {
        #if os(macOS)
        LocalAgentKind(rawValue: savedChatProvider) == nil
        #else
        true
        #endif
    }

    var requiresSubscriptionForChat: Bool {
        usesCloudChat && !environment.subscription.isActive
    }

    var requiresSubscriptionForVoice: Bool {
        voiceEngine == .chippy && !environment.subscription.isActive
    }

    func sendMessage(_ text: String? = nil) {
        if requiresSubscriptionForChat {
            inputFocused = false
            interactionFeedback += 1
            showsSubscription = true
            return
        }
        if let text {
            model.send(text)
        } else {
            model.send()
        }
    }

    var composerControlSize: CGFloat {
        #if os(macOS)
        32
        #else
        44
        #endif
    }

    var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                Button {
                    inputFocused = false
                    interactionFeedback += 1
                    showsFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .frame(width: composerControlSize, height: composerControlSize)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .help("Attach Files")
                .accessibilityLabel("Attach Files")
                .accessibilityIdentifier("chat-attach-files")
                .disabled(model.isStreaming || model.files.uploadProgress != nil || model.files.attachments.count >= ChatFileAttachment.maxCount)

                TextField(placeholder, text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, minHeight: composerControlSize, alignment: .leading)
                    .onSubmit { if canSend { sendMessage() } }
                    .submitLabel(.send)
                    .accessibilityIdentifier("chat-input")
            }
            HStack(spacing: 2) {
                ChatModelPickerButton(cloud: environment.cloudChatModels, isSubscribed: environment.subscription.isActive, controlSize: composerControlSize) {
                    inputFocused = false
                    interactionFeedback += 1
                    showsAIModels = true
                }
                .disabled(model.isStreaming)
                Spacer(minLength: 2)
                #if os(macOS)
                Button {
                    inputFocused = false
                    showsVoiceEngines = true
                    interactionFeedback += 1
                } label: {
                    Image(systemName: voiceEngine.symbolName)
                        .frame(width: composerControlSize, height: composerControlSize)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .help("Choose who answers in voice chat")
                .accessibilityLabel("Voice agent")
                .accessibilityValue(voiceEngine.title)
                .accessibilityIdentifier("chat-voice-agent")
                #endif
                Button {
                    inputFocused = false
                    if requiresSubscriptionForVoice {
                        interactionFeedback += 1
                        showsSubscription = true
                        return
                    }
                    let language = LocalVoiceLanguage.resolve(saved: savedVoiceLanguage.isEmpty ? nil : savedVoiceLanguage)
                    voice.start(api: environment.api, chat: model, engine: voiceEngine, language: language)
                } label: {
                    Image(systemName: "mic.fill")
                        .frame(width: composerControlSize, height: composerControlSize)
                        .contentShape(Rectangle())
                }
                .disabled(model.isStreaming || model.files.uploadProgress != nil || !model.files.attachments.isEmpty)
                .help("Start voice chat")
                .accessibilityLabel("Start voice chat")
                .accessibilityIdentifier("chat-voice-start")
                sendButton
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .platformGlassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer")
    }

    var sendButton: some View {
        Button {
            if model.isStreaming { model.stop() } else { sendMessage() }
        } label: {
            Image(systemName: model.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: composerControlSize - 8))
                .frame(width: composerControlSize, height: composerControlSize)
                .contentShape(Rectangle())
        }
        .foregroundStyle(model.isStreaming || canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .disabled(!model.isStreaming && !canSend)
        .accessibilityLabel(model.isStreaming ? Text("Stop") : Text("Send"))
        .accessibilityIdentifier(model.isStreaming ? "chat-stop" : "chat-send")
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
                VStack(alignment: .leading, spacing: 6) {
                    if !entry.text.isEmpty {
                        Text(entry.text)
                            .textSelection(.enabled)
                    }
                    ForEach(entry.attachments ?? []) { file in
                        Label(file.filename, systemImage: file.mimeType.hasPrefix("image/") ? "photo" : "doc.text")
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
