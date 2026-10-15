#if DEBUG
import SummaryKit
import SwiftUI

/// Offline fixture for exercising the real renderer on both Apple platforms.
struct MiniAppPreviewHost: View {
    @State private var model: MiniAppRuntime
    init() {
        var document = MiniAppDocument.blank(title: "Clip Controls")
        document.initialState = ["name": .string(""), "saved": .string("No entry"), "enabled": .bool(true), "choice": .string("A"), "date": .string("2026-10-15T00:00:00Z"),
                                 "briefings": .array([.object(["title": .string("Morning Briefing"), "summary": .string("Markets opened higher."), "detail": .string("Tech led the gains.")])])]
        func action(_ source: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }
        document.actions = [
            "open": action(#"{"trigger":"read","steps":[{"type":"present","target":"editor"}]}"#),
            "save": action(#"{"trigger":"interaction","steps":[{"type":"set","path":"saved","value":{"get":"state.name"}},{"type":"dismiss"}]}"#),
            "confirm": action(#"{"trigger":"read","steps":[{"type":"present","target":"confirmDialog"}]}"#),
            "clear": action(#"{"trigger":"interaction","steps":[{"type":"set","path":"saved","value":"Cleared"}]}"#),
            "refresh": action(#"{"trigger":"read","steps":[{"type":"set","path":"saved","value":"Refreshed"}]}"#),
            "info": action(#"{"trigger":"read","steps":[{"type":"present","target":"infoAlert"}]}"#),
            "openBriefing": action(#"{"trigger":"read","steps":[{"type":"present","target":"briefingPage"}]}"#),
            "openDetail": action(#"{"trigger":"read","steps":[{"type":"present","target":"detailPage"}]}"#),
            "back": action(#"{"trigger":"read","steps":[{"type":"dismiss"}]}"#)
        ]
        document.ui.elements = [
            "root": MiniAppNode(type: "Navigation", props: ["title": .string(document.title), "searchable": .bool(true)], children: ["saved", "search", "add", "clear", "briefingRow", "tools"], events: ["refresh": "refresh"]),
            "saved": MiniAppNode(type: "Text", props: ["text": .object(["get": .string("state.saved")])]),
            "search": MiniAppNode(type: "Text", props: ["text": .object(["get": .string("state.search")])]),
            "add": MiniAppNode(type: "Button", props: ["title": .string("Add Entry"), "icon": .string("plus")], events: ["press": "open"]),
            "clear": MiniAppNode(type: "Button", props: ["title": .string("Clear Entry")], events: ["press": "confirm"]),
            "briefingRow": MiniAppNode(type: "Button", props: ["title": .object(["get": .string("item.title")])], repeat: .object(["items": .object(["get": .string("state.briefings")])]), events: ["press": "openBriefing"]),
            "briefingPage": MiniAppNode(type: "Navigation", props: ["title": .object(["get": .string("item.title")])], children: ["briefingSummary", "openDetail"]),
            "briefingSummary": MiniAppNode(type: "Text", props: ["text": .object(["get": .string("item.summary")])]),
            "openDetail": MiniAppNode(type: "Button", props: ["title": .string("Read Detail")], events: ["press": "openDetail"]),
            "detailPage": MiniAppNode(type: "Navigation", props: ["title": .string("Detail")], children: ["detailText", "doneDetail"]),
            "detailText": MiniAppNode(type: "Text", props: ["text": .object(["get": .string("item.detail")])]),
            "doneDetail": MiniAppNode(type: "Button", props: ["title": .string("Done Reading")], events: ["press": "back"]),
            "tools": MiniAppNode(type: "Toolbar", children: ["menu"]),
            "menu": MiniAppNode(type: "Menu", props: ["title": .string("Options")], children: ["info", "refresh"]),
            "info": MiniAppNode(type: "Button", props: ["title": .string("About")], events: ["press": "info"]),
            "refresh": MiniAppNode(type: "Button", props: ["title": .string("Refresh")], events: ["press": "refresh"]),
            "editor": MiniAppNode(type: "Sheet", props: ["title": .string("New Entry")], children: ["form"]),
            "form": MiniAppNode(type: "Form", children: ["section"]),
            "section": MiniAppNode(type: "Section", props: ["title": .string("Details")], children: ["name", "toggle", "picker", "date", "save"]),
            "name": MiniAppNode(type: "TextField", props: ["title": .string("Name"), "binding": .string("name"), "required": .bool(true)]),
            "toggle": MiniAppNode(type: "Toggle", props: ["title": .string("Enabled"), "binding": .string("enabled")]),
            "picker": MiniAppNode(type: "Picker", props: ["title": .string("Category"), "binding": .string("choice"), "options": .array([.string("A"), .string("B")])]),
            "date": MiniAppNode(type: "DatePicker", props: ["title": .string("Date"), "binding": .string("date")]),
            "save": MiniAppNode(type: "Button", props: ["title": .string("Save Entry")], events: ["press": "save"]),
            "confirmDialog": MiniAppNode(type: "Confirmation", props: ["title": .string("Clear saved entry?")], children: ["confirmClear"]),
            "confirmClear": MiniAppNode(type: "Button", props: ["title": .string("Clear Now"), "role": .string("destructive")], events: ["press": "clear"]),
            "infoAlert": MiniAppNode(type: "Alert", props: ["title": .string("Native Controls"), "message": .string("Your presentation state is preserved.")])
        ]
        let api = SummaryAPIClient(baseURL: URL(string: "https://example.invalid")!, tokenProvider: MiniPreviewToken())
        _model = State(initialValue: MiniAppRuntime(api: api, document: document))
    }
    var body: some View { NavigationStack { MiniAppRuntimeView(model: model) } }
}
/// Offline fixture for the Clip loading screen; the progress bar fills over a few seconds.
struct MiniAppLoadingPreviewHost: View {
    @State private var progress = 0.06
    var body: some View {
        NavigationStack { MiniAppLoadingView(title: "Habit Tracker", progress: progress, status: progress < 0.7 ? "Loading…" : "Starting…") }
            .task {
                while progress < 0.95 {
                    try? await Task.sleep(for: .milliseconds(400))
                    progress += 0.12
                }
            }
    }
}
private struct MiniPreviewToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { throw URLError(.notConnectedToInternet) }
}
#endif
