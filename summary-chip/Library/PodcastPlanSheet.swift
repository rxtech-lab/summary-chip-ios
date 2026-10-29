import SummaryKit
import SwiftUI

/// Plan mode: a chat with the podcast planner. The latest plan sits at the end of the transcript as a card whose
/// lines open their own editor; messages revise the script and camera storyboard. Nothing is voiced or rendered
/// until the plan is confirmed.
struct PodcastPlanSheet: View {
    let api: SummaryAPIClient
    let onConfirm: (PodcastPlan) -> Void
    let onSave: (PodcastPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plan: PodcastPlan
    @State private var message = ""
    /// The request being answered, shown in the transcript until the reply arrives.
    @State private var pendingMessage: String?
    @State private var drawingFrames = false
    @State private var editingLine: PlanLine?
    @State private var previewingLine: PlanLine?
    @State private var confirming = false
    @State private var error: String?
    @State private var sends = 0
    @State private var taps = 0
    @FocusState private var composerFocused: Bool

    private struct PlanLine: Identifiable { let id: Int }
    private var busy: Bool { pendingMessage != nil || drawingFrames }

    init(api: SummaryAPIClient, initial: PodcastPlan, onConfirm: @escaping (PodcastPlan) -> Void, onSave: @escaping (PodcastPlan) -> Void) {
        self.api = api; self.onConfirm = onConfirm; self.onSave = onSave
        _plan = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        PlanChatBubble(role: .assistant, text: String(localized: "Here's a plan with the script and camera storyboard. Ask me to change anything, or tap a line to edit it yourself."))
                        ForEach(plan.messages) { PlanChatBubble(role: $0.role, text: $0.text) }
                        if let pendingMessage {
                            PlanChatBubble(role: .user, text: pendingMessage)
                            PlanWorkingBubble(text: String(localized: "Revising the plan…"))
                        }
                        PodcastPlanCard(plan: plan, drawingFrames: drawingFrames, editable: !busy,
                                        onEditLine: { taps += 1; editingLine = PlanLine(id: $0) },
                                        onDrawFrames: drawFrames,
                                        onPreview: { taps += 1; previewingLine = PlanLine(id: $0) })
                            .id("plan")
                    }
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: plan.revision) { withAnimation { proxy.scrollTo("plan", anchor: .top) } }
                .onChange(of: pendingMessage) { if pendingMessage != nil { withAnimation { proxy.scrollTo("plan", anchor: .top) } } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Podcast Plan")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(pendingMessage != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm & Generate", action: requestGeneration)
                        .disabled(!plan.isValid || busy)
                        .accessibilityIdentifier("podcast-plan-confirm")
                }
            }
            .sheet(item: $editingLine) { line in
                PodcastPlanLineSheet(api: api, plan: plan, index: line.id) { updated in apply(updated) }
            }
            .sheet(item: $previewingLine) { line in
                PodcastStoryboardSheet(plan: plan, index: line.id)
            }
#if !os(macOS)
            .confirmationDialog("Generate this podcast?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Use This Script and Storyboard", action: confirmGeneration)
                Button("Keep Reviewing", role: .cancel) {}
            } message: {
                if plan.missingFrameCount > 0 {
                    Text("Generation uses points and follows the script and camera storyboard you reviewed. Shots without a frame are designed from their camera direction.")
                } else {
                    Text("Generation uses points and follows the script, camera storyboard and frames you reviewed.")
                }
            }
#endif
            .alert("Couldn't Update Plan", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task { if plan.missingFrameCount == plan.script.segments.prefix(40).count { drawFrames() } }
            .sensoryFeedback(.impact, trigger: sends)
            .sensoryFeedback(.success, trigger: plan.revision)
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.error, trigger: error)
        }
        .interactiveDismissDisabled(pendingMessage != nil)
        .frame(minWidth: 520, idealWidth: 700, minHeight: 600, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func requestGeneration() {
        guard plan.isValid, !busy else { return }
        taps += 1
#if os(macOS)
        confirmGeneration()
#else
        confirming = true
#endif
    }

    private func confirmGeneration() {
        onSave(plan)
        onConfirm(plan)
        dismiss()
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask to change the script or storyboard…", text: $message, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .onSubmit(send)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                .accessibilityIdentifier("podcast-plan-message")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("podcast-plan-send")
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !busy && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.utf16.count <= 2000
    }

    private func send() {
        guard canSend else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        message = ""
        pendingMessage = text
        sends += 1
        Task {
            do {
                apply(try await api.refinePodcastPlan(plan, message: text))
            } catch {
                message = text
                self.error = error.localizedDescription
            }
            pendingMessage = nil
            drawFramesIfNeeded()
        }
    }

    private func apply(_ updated: PodcastPlan) {
        plan = updated
        onSave(updated)
        drawFramesIfNeeded()
    }

    private func drawFramesIfNeeded() {
        if plan.missingFrameCount > 0 { drawFrames() }
    }

    private func drawFrames() {
        guard !busy, plan.missingFrameCount > 0 else { return }
        drawingFrames = true
        Task {
            do {
                let updated = try await api.drawPodcastPlanFrames(plan)
                plan = updated
                onSave(updated)
            } catch { self.error = error.localizedDescription }
            drawingFrames = false
        }
    }
}

private struct PlanChatBubble: View {
    let role: PodcastPlan.Message.Role
    let text: String
    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 60) }
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(role == .user ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(role == .user ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary)))
            if role == .assistant { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
    }
}

private struct PlanWorkingBubble: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        .accessibilityIdentifier("podcast-plan-working")
    }
}

/// The latest plan: title, summary and every spoken line with its storyboard frame and camera direction.
private struct PodcastPlanCard: View {
    let plan: PodcastPlan
    let drawingFrames: Bool
    let editable: Bool
    let onEditLine: (Int) -> Void
    let onDrawFrames: () -> Void
    let onPreview: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("PLAN").font(.caption2.weight(.bold)).tracking(0.8)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.tint.opacity(0.18)))
                    .foregroundStyle(.tint)
                if plan.revision > 0 { Text("Revision \(plan.revision)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(plan.script.segments.count) lines").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.script.title).font(.title3.weight(.bold))
                if let summary = plan.script.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            framesStatus
            Divider()
            ForEach(plan.script.segments.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    Button { onPreview(index) } label: {
                        PlanFrameImage(url: plan.frame(at: index), storyboard: plan.storyboard == true && index < 40, drawing: drawingFrames)
                            .frame(width: 128, height: 72)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "play.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7)).padding(4)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview storyboard")
                    .accessibilityIdentifier("podcast-plan-preview-\(index)")
                    Button { onEditLine(index) } label: {
                        PlanLineRow(index: index, segment: plan.script.segments[index], speaker: plan.speakerName(for: plan.script.segments[index]))
                    }
                    .buttonStyle(.plain)
                    .disabled(!editable)
                    .accessibilityHint("Edit this line")
                    .accessibilityIdentifier("podcast-plan-line-\(index)")
                }
                if index < plan.script.segments.count - 1 { Divider().padding(.leading, 140) }
            }
            Text("Generation uses points and follows the script and storyboard you reviewed.")
                .font(.caption).foregroundStyle(.secondary)

        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcast-plan-card")
    }

    @ViewBuilder private var framesStatus: some View {
        if drawingFrames {
            Label { Text("Drawing storyboard frames…") } icon: { ProgressView().controlSize(.small) }
                .font(.callout).foregroundStyle(.secondary)
        } else if plan.missingFrameCount > 0 {
            Button(action: onDrawFrames) {
                Label("Draw \(plan.missingFrameCount) Missing Frames", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(!editable)
            .accessibilityIdentifier("podcast-plan-draw-frames")
        }
    }
}

private struct PlanLineRow: View {
    let index: Int
    let segment: PodcastPlan.Segment
    let speaker: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(index + 1)").font(.caption2.weight(.bold)).monospacedDigit()
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(.quaternary))
                    Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                Text(segment.caption).font(.callout).lineLimit(4).multilineTextAlignment(.leading)
                Label(segment.camera, systemImage: "video").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PlanFrameImage: View {
    let url: URL?
    let storyboard: Bool
    let drawing: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if phase.error != nil { Image(systemName: "photo").foregroundStyle(.secondary) }
                    else { ProgressView().controlSize(.small) }
                }
            } else if storyboard && drawing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: storyboard ? "photo" : "video").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A keyframe animatic of the planned motion, separate from the final rendered video.
private struct PodcastStoryboardSheet: View {
    let plan: PodcastPlan
    let index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var phase = 0
    @State private var playing = false
    private var sequence: Bool { plan.frameLayout == "sequence-2x2" }
    private var stages: [LocalizedStringKey] { ["Entrance", "Build", "Emphasis", "Transition"] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AsyncImage(url: plan.frame(at: index)) { state in
                        if let image = state.image {
                            GeometryReader { geometry in
                                image.resizable()
                                    .frame(width: geometry.size.width * (sequence ? 2 : 1),
                                           height: geometry.size.height * (sequence ? 2 : 1))
                                    .offset(x: sequence ? -CGFloat(phase % 2) * geometry.size.width : 0,
                                            y: sequence ? -CGFloat(phase / 2) * geometry.size.height : 0)
                            }
                            .clipped()
                        } else if state.error != nil || plan.frame(at: index) == nil {
                            ContentUnavailableView("Storyboard unavailable", systemImage: "photo")
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    if sequence {
                        HStack {
                            Button { playing.toggle() } label: {
                                Label(playing ? "Pause" : "Play Keyframes", systemImage: playing ? "pause.fill" : "play.fill")
                            }
                            .disabled(plan.frame(at: index) == nil)
                            .accessibilityIdentifier("podcast-storyboard-play")
                            Spacer()
                            Text(stages[phase]).font(.headline)
                            Text("\(phase + 1)/4").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Picker("Keyframe", selection: $phase) {
                            ForEach(0..<4, id: \.self) { step in Text(stages[step]).tag(step) }
                        }
                        .pickerStyle(.segmented)
                        Text("Keyframe preview of the planned animation. Final motion is rendered after generation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(plan.script.segments[index].caption).font(.headline).textSelection(.enabled)
                    Label("Animation & Content", systemImage: "film.stack").font(.subheadline.weight(.semibold))
                    Text(plan.script.segments[index].camera).textSelection(.enabled)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Storyboard")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: playing) {
                guard playing else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                    phase = (phase + 1) % 4
                }
            }
            .sensoryFeedback(.selection, trigger: playing)
        }
#if os(macOS)
        .frame(minWidth: 520, idealWidth: 800, minHeight: 600, maxHeight: .infinity)
#else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}

/// Edits one spoken line: who speaks it, the exact words and the camera direction. Saving creates a new revision.
private struct PodcastPlanLineSheet: View {
    let api: SummaryAPIClient
    let plan: PodcastPlan
    let index: Int
    let onSaved: (PodcastPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var segment: PodcastPlan.Segment
    @State private var saving = false
    @State private var deleting = false
    @State private var error: String?
    @State private var saves = 0

    init(api: SummaryAPIClient, plan: PodcastPlan, index: Int, onSaved: @escaping (PodcastPlan) -> Void) {
        self.api = api; self.plan = plan; self.index = index; self.onSaved = onSaved
        _segment = State(initialValue: plan.script.segments[index])
    }

    private var original: PodcastPlan.Segment { plan.script.segments[index] }
    private var valid: Bool {
        let caption = segment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = segment.camera.trimmingCharacters(in: .whitespacesAndNewlines)
        return !caption.isEmpty && caption.utf16.count <= 500 && !camera.isEmpty && camera.utf16.count <= 2000
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlanFrameImage(url: segment.camera == original.camera ? plan.frame(at: index) : nil,
                                   storyboard: plan.storyboard == true && index < 40, drawing: false)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if plan.storyboard == true && index < 40 {
                        if segment.camera == original.camera { Text("The storyboard frame for this line.") }
                        else { Text("Saving redraws this frame from the new camera direction. Drawing uses points.") }
                    }
                }
                Section("Speaker") {
                    Picker("Speaker", selection: $segment.speaker) {
                        ForEach(plan.script.speakers.indices, id: \.self) { Text(plan.script.speakers[$0].name).tag($0) }
                    }
                    .disabled(plan.script.speakers.count < 2)
                }
                Section {
                    TextField("Spoken script", text: $segment.caption, axis: .vertical).lineLimit(4...12)
                        .accessibilityIdentifier("podcast-plan-line-caption")
                } header: { Text("Script") } footer: {
                    Text("\(segment.caption.utf16.count)/500 characters").monospacedDigit()
                }
                Section {
                    TextField("Composition, camera movement and transition", text: $segment.camera, axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("podcast-plan-line-camera")
                } header: { Text("Camera Direction") }
                if plan.script.segments.count > 1 {
                    Section {
                        Button("Delete Line", role: .destructive) { deleting = true }
                            .accessibilityIdentifier("podcast-plan-line-delete")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Line \(index + 1)")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save { $0.script.segments[index] = trimmed } }
                        .disabled(saving || !valid || segment == original)
                        .accessibilityIdentifier("podcast-plan-line-save")
                }
            }
            .disabled(saving)
            .overlay {
                if saving {
                    ProgressView("Saving line…").padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .confirmationDialog("Delete this line?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete Line", role: .destructive) { save { $0.script.segments.remove(at: index) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The line and its storyboard shot are removed from the plan.") }
            .alert("Couldn't Save Line", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.impact, trigger: saving)
            .sensoryFeedback(.success, trigger: saves)
            .sensoryFeedback(.error, trigger: error)
            .sensoryFeedback(.selection, trigger: segment.speaker)
        }
        .interactiveDismissDisabled(saving)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 520, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private var trimmed: PodcastPlan.Segment {
        var line = segment
        line.caption = line.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        line.camera = line.camera.trimmingCharacters(in: .whitespacesAndNewlines)
        return line
    }

    private func save(_ change: (inout PodcastPlan) -> Void) {
        var updated = plan
        change(&updated)
        saving = true
        Task {
            do {
                let saved = try await api.revisePodcastPlan(updated)
                saves += 1
                onSaved(saved)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
