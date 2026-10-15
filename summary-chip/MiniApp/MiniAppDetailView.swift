import SummaryKit
import SwiftUI

struct MiniAppDetailView: View {
    let environment: AppEnvironment
    let appID: String
    @State private var runtime: MiniAppRuntime?
    @State private var error: String?
    @State private var showsEditor = false
    @State private var showsChat = false
    @State private var management: MiniManagementSection?
    @State private var versions: DocumentVersionsModel
    @State private var confirmsCover = false
    @State private var isGeneratingCover = false
    @State private var coverUpdated = false
    @State private var coverError: String?

    init(environment: AppEnvironment, appID: String) {
        self.environment = environment; self.appID = appID
        _versions = State(initialValue: DocumentVersionsModel(api: environment.api, id: appID))
    }
    var body: some View {
        Group {
            if let runtime {
                if case .miniApp(let document) = versions.preview?.content {
                    MiniAppVersionPreview(api: environment.api, document: document).id(versions.preview?.id)
                } else { MiniAppRuntimeView(model: runtime) }
            } else if let error { ContentUnavailableView("Clip Unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView() }
        }
        .navigationTitle(runtime?.document.title ?? "Clip")
        .task { await reload() }
        .toolbar {
            // One More menu, so the Clip's own toolbar items keep the bar.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if runtime?.app?.isOwner == true {
                        Section {
                            Button("Edit with AI", systemImage: "sparkles") { showsChat = true }
                            Button("Edit Definition", systemImage: "curlybraces") { showsEditor = true }
                            VersionToolbarMenu(model: versions)
                        }
                        Section {
                            Button("Sharing", systemImage: "person.2") { management = .sharing }
                            Button("Generate Cover", systemImage: "wand.and.stars") { confirmsCover = true }
                                .disabled(isGeneratingCover)
                                .accessibilityIdentifier("mini-app-generate-cover")
                        }
                    }
                    Section {
                        Button("Data", systemImage: "tablecells") { management = .data }
                        Button("Connections", systemImage: "link") { management = .connections }
                        Button("Reload", systemImage: "arrow.clockwise") { Task { await reload() } }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                    .accessibilityIdentifier("mini-app-more")
            }
        }
        .safeAreaInset(edge: .bottom) { if versions.isPreviewing { VersionPreviewBanner(model: versions) } }
        .overlay(alignment: .top) {
            if isGeneratingCover || coverUpdated {
                Label(isGeneratingCover ? "Designing a new cover…" : "Cover updated", systemImage: isGeneratingCover ? "hourglass" : "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("mini-app-cover-status")
            }
        }
        .animation(.spring(duration: 0.35), value: isGeneratingCover)
        .animation(.spring(duration: 0.35), value: coverUpdated)
        .sensoryFeedback(.success, trigger: coverUpdated) { _, new in new }
        .sensoryFeedback(.error, trigger: coverError) { _, new in new != nil }
        .confirmationDialog("Generate a new cover?", isPresented: $confirmsCover, titleVisibility: .visible) {
            Button("Generate Cover") { Task { await generateCover() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new illustration replaces the Clip's current cover.")
        }
        .statusAlert("Couldn't Generate Cover", message: coverError) { coverError = nil }
        .documentVersions(versions) { _ in Task { await reload() } }
        .sheet(isPresented: $showsEditor) {
            if let runtime, let app = runtime.app {
                MiniAppDefinitionSheet(api: environment.api, app: app) { updated in runtime.app = updated; runtime.document = updated.document; runtime.state = updated.document.initialState; Task { await versions.reload() } }
            }
        }
        .sheet(isPresented: $showsChat, onDismiss: { Task { await reload() } }) {
            ChatView(environment: environment, miniAppID: appID)
        }
        .sheet(item: $management) { section in
            if let app = runtime?.app { MiniAppManagementSheet(api: environment.api, app: app, section: section) }
        }
    }
    /// Designs a new illustrated cover for the app's library card.
    private func generateCover() async {
        isGeneratingCover = true
        do {
            let updated = try await environment.api.regenerateImage(id: appID, style: .illustration)
            isGeneratingCover = false
            environment.library.upsert(updated)
            coverUpdated = true
            try? await Task.sleep(for: .seconds(1.6))
            coverUpdated = false
        } catch is CancellationError {
            isGeneratingCover = false
        } catch {
            isGeneratingCover = false
            coverError = error.localizedDescription
        }
    }
    private func reload() async {
        do {
            let app = try await environment.api.miniApp(id: appID)
            if let runtime {
                let changed = runtime.app?.revision != app.revision
                runtime.app = app; runtime.document = app.document
                if changed { runtime.state = app.document.initialState }
                else if let action = app.document.ui.elements[app.document.ui.root]?.events["load"] { await runtime.run(action) }
            }
            else { runtime = MiniAppRuntime(api: environment.api, document: app.document, app: app) }
            if app.isOwner { await versions.reload() }
        } catch { self.error = error.localizedDescription }
    }
}

private struct MiniAppVersionPreview: View {
    @State private var model: MiniAppRuntime
    init(api: SummaryAPIClient, document: MiniAppDocument) { _model = State(initialValue: MiniAppRuntime(api: api, document: document)) }
    var body: some View { MiniAppRuntimeView(model: model) }
}

struct NewMiniAppSheet: View {
    let environment: AppEnvironment
    let onCreated: (MiniApp) -> Void
    @State private var title = "My Clip"
    @State private var template = "blank"
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                Picker("Start with", selection: $template) {
                    Text("Blank app").tag("blank")
                    Text("Personal tracker").tag("tracker")
                }
                Text("Create your app, then describe what you want with Edit with AI. You can also build one directly in Chat.").foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("New Clip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await create() } }.disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .overlay { if busy { ProgressView() } }
            .statusAlert("Clip", message: error) { error = nil }
        }.summarySheetSize()
    }
    private func create() async {
        busy = true; defer { busy = false }
        do {
            var document = MiniAppDocument.blank(title: title)
            if template == "tracker" {
                let catalog = try await environment.api.miniAppCatalog()
                if let example = catalog["examples"]?.miniArray.first { document = try example.decode(MiniAppDocument.self); document.title = title }
            }
            let app = try await environment.api.createMiniApp(document)
            onCreated(app); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct MiniAppPreviewView: View {
    let environment: AppEnvironment
    @State private var runtime: MiniAppRuntime
    @State private var saved: MiniApp?
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    init(environment: AppEnvironment, document: MiniAppDocument) {
        self.environment = environment
        _runtime = State(initialValue: MiniAppRuntime(api: environment.api, document: document))
    }
    var body: some View {
        NavigationStack {
            MiniAppRuntimeView(model: runtime)
                .safeAreaInset(edge: .bottom) {
                    Text(saved == nil ? "Preview uses sample data and simulated API responses." : "Saved to Clips.")
                        .font(.footnote).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if let saved { NavigationLink("Open App") { MiniAppDetailView(environment: environment, appID: saved.id) } }
                        else { Button("Save App", systemImage: "square.and.arrow.down") { Task { await save() } }.disabled(busy) }
                    }
                }
                .statusAlert("Clip", message: error) { error = nil }
        }.summarySheetSize()
    }
    private func save() async {
        busy = true; defer { busy = false }
        do { saved = try await environment.api.createMiniApp(runtime.document); await environment.library.reload() }
        catch { self.error = error.localizedDescription }
    }
}

struct MiniAppDefinitionSheet: View {
    let api: SummaryAPIClient
    let app: MiniApp
    let onSaved: (MiniApp) -> Void
    @State private var text: String
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    init(api: SummaryAPIClient, app: MiniApp, onSaved: @escaping (MiniApp) -> Void) {
        self.api = api; self.app = app; self.onSaved = onSaved
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        _text = State(initialValue: String(data: (try? encoder.encode(app.document)) ?? Data(), encoding: .utf8) ?? "")
    }
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding()
                .navigationTitle("Edit Definition")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy) }
                }
                .statusAlert("Definition", message: error) { error = nil }
        }.summarySheetSize()
    }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            let document = try JSONDecoder().decode(MiniAppDocument.self, from: Data(text.utf8))
            onSaved(try await api.updateMiniApp(id: app.id, document: document, revision: app.revision)); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
