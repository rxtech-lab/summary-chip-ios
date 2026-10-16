import Observation
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

struct MiniPresentation: Identifiable, Hashable { let id: String }

@Observable
final class MiniAppRuntime {
    let api: SummaryAPIClient
    var app: MiniApp?
    var document: MiniAppDocument
    var state: [String: JSONValue]
    var records: [String: [JSONValue]]?
    var presentation: MiniPresentation?
    var dialog: MiniPresentation?
    var alert: MiniPresentation?
    var navigation: MiniPresentation?
    private var pendingReads: [String: (item: JSONValue, input: [String: JSONValue])] = [:]
    var presentationItem: JSONValue = .null
    /// A file from an `export` or `download` step, waiting for the Save dialog.
    var file: MiniAppFile?
    var error: String?
    var busy = false
    var feedback = 0
    var search = ""

    init(api: SummaryAPIClient, document: MiniAppDocument, app: MiniApp? = nil) {
        self.api = api; self.document = document; self.app = app; self.state = document.initialState
    }
    func value(_ value: JSONValue?, item: JSONValue = .null) -> JSONValue {
        MiniAppExpression.evaluate(value ?? .null, context: ["state": .object(state), "item": item, "input": .object([:])])
    }
    func binding(_ path: String) -> Binding<JSONValue> {
        Binding(get: { MiniAppExpression.read(.object(self.state), path: path) }, set: { MiniAppExpression.write(&self.state, path: path, value: $0) })
    }
    func event(_ node: MiniAppNode, _ name: String, item: JSONValue = .null) {
        guard let action = node.events[name] else { return }
        Task { await run(action, item: item, input: value(node.props["input"], item: item).miniObject) }
    }
    func run(_ action: String, item: JSONValue = .null, input: [String: JSONValue] = [:]) async {
        guard !busy else {
            if document.actions[action]?["trigger"]?.stringValue == "read" { pendingReads[action] = (item, input) }
            return
        }
        busy = true; feedback += 1
        defer {
            busy = false
            if let next = pendingReads.first {
                pendingReads.removeValue(forKey: next.key)
                Task { await run(next.key, item: next.value.item, input: next.value.input) }
            }
        }
        do {
            if document.actions[action]?["trigger"]?.stringValue == "interaction" { try validateForm() }
            let steps = document.actions[action]?["steps"]?.miniArray ?? []
            if isLocal(steps) {
                var budget = 50
                applyLocal(steps, item: item, input: input, budget: &budget)
            } else if let app, runsOnDevice(steps) {
                let startingState = state
                var working = state; var effects: [JSONValue] = []; var budget = 50
                try await runOnDevice(steps, app: app, item: item, input: input, state: &working, effects: &effects, budget: &budget, deadline: .now + 30)
                for (key, value) in state where startingState[key] != value { working[key] = value }
                state = working
                for effect in effects { try await apply(effect, item: item) }
            } else {
                let startingState = state
                let result = try await api.miniAppAction(id: app?.id, document: document, revision: app?.revision ?? 0, action: action, state: state, input: input, item: item, records: records)
                var merged = result.state
                for (key, value) in state where startingState[key] != value { merged[key] = value }
                state = merged
                if let records = result.records { self.records = records }
                for effect in result.effects { try await apply(effect, item: item) }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func isLocal(_ steps: [JSONValue]) -> Bool {
        steps.allSatisfy { step in
            if step["type"]?.stringValue == "if" { return isLocal(step["then"]?.miniArray ?? []) && isLocal(step["else"]?.miniArray ?? []) }
            return ["set", "present", "dismiss", "export"].contains(step["type"]?.stringValue ?? "")
        }
    }
    /// Keyless API requests go straight from the device; scripts still run in the server sandbox.
    /// Queries, mutations and credentialed connectors keep the whole action on the server.
    private func runsOnDevice(_ steps: [JSONValue]) -> Bool {
        steps.allSatisfy { step in
            switch step["type"]?.stringValue {
            case "if": runsOnDevice(step["then"]?.miniArray ?? []) && runsOnDevice(step["else"]?.miniArray ?? [])
            case "set", "present", "dismiss", "script", "export", "download": true
            case "request": MiniAppPublicAPI.isPublic(step["connector"]?.stringValue.flatMap { document.connectors[$0] })
            default: false
            }
        }
    }
    private func runOnDevice(_ steps: [JSONValue], app: MiniApp, item: JSONValue, input: [String: JSONValue], state: inout [String: JSONValue], effects: inout [JSONValue], budget: inout Int, deadline: Date) async throws {
        for step in steps {
            guard budget > 0, Date.now < deadline else { throw MiniActionError.limit }
            budget -= 1
            let context: [String: JSONValue] = ["state": .object(state), "item": item, "input": .object(input)]
            func evaluated(_ key: String) -> JSONValue { MiniAppExpression.evaluate(step[key] ?? .null, context: context) }
            switch step["type"]?.stringValue {
            case "if":
                try await runOnDevice(step[evaluated("condition").miniTruth ? "then" : "else"]?.miniArray ?? [], app: app, item: item, input: input, state: &state, effects: &effects, budget: &budget, deadline: deadline)
            case "set":
                if let path = step["path"]?.stringValue { MiniAppExpression.write(&state, path: path, value: evaluated("value")) }
            case "request":
                let connector = step["connector"]?.stringValue ?? ""
                let result = try await MiniAppPublicAPI.call(connector: document.connectors[connector], operation: step["operation"]?.stringValue ?? "", input: evaluated("input"))
                if let path = step["into"]?.stringValue { MiniAppExpression.write(&state, path: path, value: result) }
            case "script":
                let result = try await api.miniAppScript(id: app.id, revision: app.revision, script: step["script"]?.stringValue ?? "", input: evaluated("input"))
                if let path = step["into"]?.stringValue { MiniAppExpression.write(&state, path: path, value: result) }
            default: effects.append(Self.evaluatedEffect(step, context: context))
            }
        }
    }
    private func applyLocal(_ steps: [JSONValue], item: JSONValue, input: [String: JSONValue], budget: inout Int) {
        for step in steps {
            guard budget > 0 else { error = "Action exceeded 50 steps."; return }
            budget -= 1
            let context: [String: JSONValue] = ["state": .object(state), "item": item, "input": .object(input)]
            switch step["type"]?.stringValue {
            case "if":
                let branch = MiniAppExpression.evaluate(step["condition"] ?? .null, context: context).miniTruth ? "then" : "else"
                applyLocal(step[branch]?.miniArray ?? [], item: item, input: input, budget: &budget)
            case "set":
                if let path = step["path"]?.stringValue { MiniAppExpression.write(&state, path: path, value: MiniAppExpression.evaluate(step["value"] ?? .null, context: context)) }
            default:
                do { try applyNow(Self.evaluatedEffect(step, context: context), item: item) } catch { self.error = error.localizedDescription; return }
            }
        }
    }
    /// File steps carry expressions; the server evaluates them, so device-run steps must match.
    private static func evaluatedEffect(_ step: JSONValue, context: [String: JSONValue]) -> JSONValue {
        guard case .object(var effect) = step, ["export", "download"].contains(step["type"]?.stringValue ?? "") else { return step }
        for key in ["filename", "content", "url"] where effect[key] != nil {
            effect[key] = MiniAppExpression.evaluate(effect[key]!, context: context)
        }
        return .object(effect)
    }
    /// Downloads run inside the action, so the busy indicator covers them.
    private func apply(_ effect: JSONValue, item: JSONValue) async throws {
        if effect["type"]?.stringValue == "download" { file = try await MiniAppFile.download(effect) } else { try applyNow(effect, item: item) }
    }
    private func applyNow(_ effect: JSONValue, item: JSONValue) throws {
        if effect["type"]?.stringValue == "export" { file = try MiniAppFile.export(effect); return }
        if effect["type"]?.stringValue == "dismiss" { presentation = nil; dialog = nil; alert = nil; navigation = nil; return }
        guard let target = effect["target"]?.stringValue, let node = document.ui.elements[target] else { return }
        presentationItem = item
        switch node.type {
        case "Navigation": navigation = MiniPresentation(id: target)
        case "Alert": alert = MiniPresentation(id: target)
        case "Confirmation", "Dialog": dialog = MiniPresentation(id: target)
        default: presentation = MiniPresentation(id: target)
        }
    }
    private func validateForm() throws {
        let root = presentation?.id ?? document.ui.root
        var pending = [root]; var seen: Set<String> = []
        while let id = pending.popLast(), seen.count < 300 {
            guard seen.insert(id).inserted, let node = document.ui.elements[id] else { continue }
            pending += node.children
            if node.props["required"]?.miniTruth == true, let path = node.props["binding"]?.stringValue,
               MiniAppExpression.read(.object(state), path: path).miniText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MiniFormError.required(node.props["title"]?.miniText ?? "Field")
            }
        }
    }
}
private enum MiniActionError: LocalizedError {
    case limit
    var errorDescription: String? { "Action exceeded its execution budget." }
}
private enum MiniFormError: LocalizedError {
    case required(String)
    var errorDescription: String? { switch self { case .required(let field): "\(field) is required." } }
}

struct MiniAppRuntimeView: View {
    @Bindable var model: MiniAppRuntime
    var body: some View {
        Group {
            if model.document.schemaVersion != 1 {
                ContentUnavailableView("Update Chippy", systemImage: "arrow.down.app", description: Text("This Clip needs a newer renderer."))
            } else {
                MiniAppNodeView(model: model, id: model.document.ui.root)
            }
        }
        .disabled(model.busy)
        .overlay(alignment: .top) { if model.busy { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .navigationDestination(item: $model.navigation) { target in
            MiniAppNodeView(model: model, id: target.id, item: model.presentationItem)
        }
        .sheet(item: $model.presentation) { target in
            NavigationStack {
                MiniAppNodeView(model: model, id: target.id, item: model.presentationItem)
                    .navigationTitle(model.document.ui.elements[target.id]?.props["title"]?.miniText ?? "")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { model.presentation = nil } } }
            }
            .modifier(MiniFileExport(model: model, active: true))
            .modifier(MiniSheetHeight(half: model.document.ui.elements[target.id]?.props["height"]?.stringValue == "half"))
        }
        .confirmationDialog(dialogTitle(model.dialog), isPresented: Binding(get: { model.dialog != nil }, set: { if !$0 { model.dialog = nil } }), titleVisibility: .visible) {
            presentationButtons(model.dialog)
        } message: { Text(dialogMessage(model.dialog)) }
        .alert(dialogTitle(model.alert), isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            presentationButtons(model.alert)
        } message: { Text(dialogMessage(model.alert)) }
        .modifier(MiniFileExport(model: model, active: model.presentation == nil))
        .statusAlert("Clip", message: model.error) { model.error = nil }
        .sensoryFeedback(.selection, trigger: model.feedback)
        .sensoryFeedback(.error, trigger: model.error)
    }
    private func dialogTitle(_ target: MiniPresentation?) -> String { target.flatMap { model.document.ui.elements[$0.id]?.props["title"]?.miniText } ?? "Clip" }
    private func dialogMessage(_ target: MiniPresentation?) -> String { target.flatMap { model.document.ui.elements[$0.id]?.props["message"]?.miniText } ?? "" }
    @ViewBuilder private func presentationButtons(_ target: MiniPresentation?) -> some View {
        if let target, let node = model.document.ui.elements[target.id] {
            ForEach(node.children, id: \.self) { id in
                if let button = model.document.ui.elements[id] {
                    Button(button.props["title"]?.miniText ?? "Continue", role: button.props["role"]?.stringValue == "destructive" ? .destructive : nil) {
                        model.event(button, "press", item: model.presentationItem)
                    }
                }
            }
        }
        Button("Cancel", role: .cancel) {}
    }
}

/// The Save dialog for `model.file`, from whichever view is frontmost: the root, or an open sheet.
private struct MiniFileExport: ViewModifier {
    @Bindable var model: MiniAppRuntime
    let active: Bool
    func body(content: Content) -> some View {
        content.fileExporter(isPresented: Binding(get: { active && model.file != nil }, set: { if !$0 { model.file = nil } }),
                             document: model.file.map(MiniFileDocument.init), contentType: .data, defaultFilename: model.file?.filename) { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
    }
}

/// Bytes for the Save dialog; the filename (with its extension) comes from the Clip.
private struct MiniFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let data: Data
    init(_ file: MiniAppFile) { data = file.data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// `height: "half"` opens a sheet at half height (draggable to full); otherwise the standard size.
private struct MiniSheetHeight: ViewModifier {
    let half: Bool
    func body(content: Content) -> some View {
        #if os(macOS)
        if half { content.frame(minWidth: 480, idealWidth: 560, minHeight: 280, idealHeight: 340) } else { content.summarySheetSize() }
        #else
        if half { content.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) } else { content.summarySheetSize() }
        #endif
    }
}
