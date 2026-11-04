#if os(visionOS)
import RealityKit
import SummaryKit
import SwiftUI

/// Spatial library entry point. Detail workflows retain their own navigation and sheets.
struct SpatialLibraryView: View {
    let environment: AppEnvironment
    @State private var selection: Summary?
    @State private var showsVoice = false
    @State private var horizontal = true

    var body: some View {
        NavigationStack {
            ScrollView(horizontal ? .horizontal : .vertical) {
                let layout = horizontal ? AnyLayout(HStackLayout(spacing: 32)) : AnyLayout(VStackLayout(spacing: 32))
                layout {
                    ForEach(environment.library.items) { summary in
                        Button { selection = summary } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                SummaryOGImage(summary: summary)
                                    .frame(height: 110).clipped()
                                Text(summary.title).font(.title2).lineLimit(4)
                            }
                            .frame(width: 260, height: 260, alignment: .leading)
                            .padding(24)
                            .glassBackgroundEffect()
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .offset(z: 30)
                    }
                    if environment.library.nextCursor != nil {
                        Button("Load more") { Task { await environment.library.loadMore() } }
                            .disabled(environment.library.isLoadingMore)
                    }
                }
                .padding(48)
            }
            .overlay {
                if environment.library.isLoading && environment.library.items.isEmpty {
                    ProgressView("Loading chips…")
                } else if environment.library.items.isEmpty {
                    ContentUnavailableView("No chips yet", systemImage: "square.stack.3d.up", description: Text(environment.library.errorMessage ?? "Your saved chips will appear here."))
                }
            }
            .navigationTitle("Chippy")
            .toolbar {
                Button(horizontal ? "Scroll vertically" : "Scroll horizontally", systemImage: "arrow.up.arrow.down") {
                    horizontal.toggle()
                }
                Button("Live voice", systemImage: "waveform") { showsVoice = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await environment.library.reload() } }
            }
            .sheet(item: $selection) { summary in
                NavigationStack {
                    Group {
                        if summary.kind == .graph {
                            SpatialGraphLauncher(graphID: summary.id)
                        } else {
                            SummaryDestination(environment: environment, summary: summary, allowsChat: false)
                        }
                    }
                        .toolbar { Button("Done") { selection = nil } }
                }
                .frame(minWidth: 700, minHeight: 600)
            }
            .sheet(isPresented: $showsVoice) { SpatialVoiceView(environment: environment) }
            .task { await environment.library.reload() }
        }
    }
}

/// A sheet entry point hands off to a plain window because visionOS sheets retain glass.
struct SpatialVoiceView: View {
    let environment: AppEnvironment
    var trip: TripChat? = nil
    var graph: GraphChat? = nil
    var onUpdated: (() -> Void)? = nil
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ProgressView("Opening live voice…")
            .task {
                let id = UUID().uuidString
                SpatialVoiceSessions.shared.views[id] = SpatialVoiceContent(
                    environment: environment, trip: trip, graph: graph, onUpdated: onUpdated)
                if let graph {
                    SpatialVoiceSessions.shared.graphSessions[graph.id] = id
                } else {
                    openWindow(id: "live-voice", value: id)
                }
                dismiss()
            }
    }
}

@MainActor
@Observable
final class SpatialVoiceSessions {
    static let shared = SpatialVoiceSessions()
    var views: [String: SpatialVoiceContent] = [:]
    var graphSessions: [String: String] = [:]
}

struct SpatialVoiceContent: View {
    let environment: AppEnvironment
    var trip: TripChat? = nil
    var graph: GraphChat? = nil
    var onUpdated: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @State private var voice = LiveVoiceModel()
    @State private var chat: ChatModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var visibleTools: [ChatToolActivity] {
        Array((chat?.entries.flatMap(\.tools) ?? [])
            .filter { $0.id == voice.currentToolID }.suffix(1))
    }

    private var messageStage: some View {
        ViewThatFits(in: .vertical) {
            responseText
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                responseText
            }
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
        // Keep the bubble content-sized, but give tool overlays room around it.
        .frame(maxWidth: .infinity)
        .padding(.vertical, visibleTools.isEmpty ? 0 : 110)
        .overlay {
            ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                toolBubble(tool)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: bubbleAlignment(index))
                    .padding(.horizontal, index.isMultiple(of: 2) ? 8 : 22)
                    .padding(.vertical, 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: visibleTools.map(\.id))
    }

    private var responseText: some View {
        Text(voice.latestResponse.isEmpty ? "Listening…" : voice.latestResponse)
            .font(.title3)
            .multilineTextAlignment(.center)
            .padding(18)
    }

    private func bubbleAlignment(_ index: Int) -> Alignment {
        switch index {
        case 0: .topLeading
        case 1: .topTrailing
        case 2: .bottomTrailing
        default: .bottomLeading
        }
    }

    private func toolBubble(_ tool: ChatToolActivity) -> some View {
        SpatialToolBubble(tool: tool)
            .id(tool.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live voice").font(.headline)
                Spacer()
                Button("Done") {
                    voice.stop()
                    if let onClose { onClose() } else { dismiss() }
                }
            }
            .padding(24)
            VStack(spacing: 24) {
                messageStage
                    .offset(z: 60)
                Button {
                    if voice.isActive { voice.stop() }
                    else if let chat { voice.start(api: environment.api, chat: chat) }
                } label: {
                    HStack(spacing: 12) {
                        VoiceInputWaveform(level: voice.inputLevel, isConnecting: voice.isConnecting)
                            .frame(width: 150, height: 40)
                        Label(voice.isActive ? "Stop live voice" : "Start live voice",
                              systemImage: voice.isActive ? "stop.fill" : "mic.fill")
                            .font(.caption)
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.isActive ? "Stop live voice" : "Start live voice")
                .sensoryFeedback(.selection, trigger: voice.isActive)
                if voice.isActive {
                    Text(voice.isSpeaking ? "Microphone paused while the agent speaks" : "Listening…")
                        .font(.caption)
                        .padding(10)
                        .glassBackgroundEffect(in: Capsule())
                }
            }
            .padding(32)
            .overlay(alignment: .bottom) {
                if voice.isConnecting { ProgressView("Connecting…").padding().glassBackgroundEffect() }
            }
            .alert("Voice chat unavailable", isPresented: Binding(get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })) {
                Button("OK") { voice.error = nil }
            } message: { Text(voice.error ?? "") }
        }
        .frame(width: 600, height: 650)
        .presentationBackground(.clear)
        .task {
            let model = ChatModel(client: environment.chatClient, store: environment.chatStore, trip: trip, graph: graph)
            model.onTripUpdated = onUpdated
            if let graph {
                // The controls window closes during voice chat. Bind to the
                // canvas session directly rather than its dismissed view state.
                let graphModel = SpatialGraphSessions.shared.model(id: graph.id, environment: environment)
                model.graphDocument = graphModel.document
                model.onGraphUpdated = { [graphModel, weak model] in
                    Task {
                        await graphModel.refresh()
                        model?.graphDocument = graphModel.document
                    }
                }
                model.onGraphSelection = { [graphModel] selection in
                    graphModel.apply(selection: selection)
                }
            }
            chat = model
            voice.start(api: environment.api, chat: model)
        }
        .onDisappear { voice.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { voice.stop() } }
    }
}
/// A translucent volumetric shell with its label suspended inside.
private struct SpatialToolBubble: View {
    let tool: ChatToolActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pushed = false

    private func updateLabel(_ root: Entity) {
        let status = tool.isRunning ? "running" : (tool.errorText == nil ? "completed" : "failed")
        let identity = tool.label + "|" + status
        guard root.children.first?.name != identity else { return }
        root.children.removeAll()
        let group = Entity()
        group.name = identity
        let mesh = MeshResource.generateText(
            tool.label, extrusionDepth: 0.8,
            font: .systemFont(ofSize: 12, weight: .semibold),
            containerFrame: CGRect(x: 0, y: 0, width: 80, height: max(100, tool.label.count * 16)),
            alignment: .center, lineBreakMode: .byWordWrapping)
        let text = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: .white, roughness: 0.35, isMetallic: false)])
        let bounds = text.visualBounds(relativeTo: text)
        let scale = min(0.0336 / max(bounds.extents.x, 0.001), 0.0304 / max(bounds.extents.y, 0.001))
        text.scale = SIMD3<Float>(repeating: scale)
        text.position = -bounds.center * scale
        text.position.y -= 0.0024
        group.addChild(text)
        let indicator = ModelEntity(mesh: .generateSphere(radius: 0.0024),
                                    materials: [UnlitMaterial(color: tool.isRunning ? .cyan : (tool.errorText == nil ? .green : .orange))])
        indicator.position = SIMD3<Float>(0, 0.020, 0)
        group.addChild(indicator)
        root.addChild(group)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 0.8
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 1.4, bounce: 0.25)) {
                    pushed.toggle()
                }
            } label: {
                RealityView { content in
                    let shell = ModelEntity(
                        mesh: .generateSphere(radius: 0.028),
                        materials: [SimpleMaterial(color: .init(red: 0.25, green: 0.8, blue: 1, alpha: 0.10),
                                                   roughness: 0.08, isMetallic: false)])
                    content.add(shell)
                    let labelRoot = Entity()
                    labelRoot.name = "tool-label"
                    updateLabel(labelRoot)
                    content.add(labelRoot)
                } update: { content in
                    if let labelRoot = content.entities.first(where: { $0.name == "tool-label" }) {
                        updateLabel(labelRoot)
                    }
                }
                .frame(width: 80, height: 80)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tool.label)
            .accessibilityValue(tool.isRunning ? "Running" : (tool.errorText == nil ? "Completed" : "Failed"))
            .accessibilityHint("Push the bubble away")
            .offset(x: reduceMotion ? 0 : sin(phase) * 14 + (pushed ? 160 : 0),
                    y: reduceMotion ? 0 : cos(phase * 0.7) * 7 + (pushed ? -24 : 0))
            .offset(z: reduceMotion ? 0 : 24 + sin(phase * 0.6) * 14 + (pushed ? -90 : 0))
            .opacity(reduceMotion && pushed ? 0.55 : 1)
            .sensoryFeedback(.selection, trigger: pushed)
        }
        .transition(.opacity)
    }
}
#endif
