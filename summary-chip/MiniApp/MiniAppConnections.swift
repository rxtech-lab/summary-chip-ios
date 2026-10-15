import AuthenticationServices
import SummaryKit
import SwiftUI

struct MiniConnections: View {
    let api: SummaryAPIClient
    let app: MiniApp
    @State private var connections: [JSONValue] = []
    @State private var connecting: MiniPresentation?
    @State private var grant: JSONValue?
    @State private var showsGrant = false
    @State private var removing: String?
    @State private var confirmsDisconnect = false
    @State private var error: String?
    var body: some View {
        List {
            if app.document.connectors.isEmpty { Text("Add an API integration with Edit with AI, then connect your account here.").foregroundStyle(.secondary) }
            ForEach(Array(Set(app.document.connectors.keys).union(connections.compactMap { $0["connector"]?.stringValue })).sorted(), id: \.self) { key in
                Section(app.document.connectors[key]?["title"]?.miniText ?? key) {
                    Text(app.document.connectors[key]?["origin"]?.miniText ?? "").font(.footnote).textSelection(.enabled)
                    ForEach(connections.filter { $0["connector"]?.stringValue == key }, id: \.self) { connection in
                        connectionRow(connection)
                    }
                    if app.document.connectors[key]?["auth"]?["type"]?.stringValue == "none" {
                        Label("Public API — no account needed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else if app.document.connectors[key] != nil {
                        Button("Connect Account", systemImage: "link.badge.plus") { connecting = MiniPresentation(id: key) }
                    } else { Text("This integration was removed from the app. You can disconnect the saved account.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .task { await load() }
        .sheet(item: $connecting, onDismiss: { Task { await load() } }) { connector in MiniConnectSheet(api: api, app: app, connector: connector.id) }
        .sheet(isPresented: $showsGrant) { if let grant { MiniGrantSheet(api: api, app: app, connection: grant) } }
        .confirmationDialog("Disconnect this account?", isPresented: $confirmsDisconnect) { Button("Disconnect", role: .destructive) { Task { await disconnect() } } }
        .statusAlert("Connections", message: error) { error = nil }
    }
    @ViewBuilder private func connectionRow(_ connection: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(connection["shared"]?.miniTruth == true ? "Shared Account" : "Your Account", systemImage: "person.crop.circle.badge.checkmark")
            Text(connection["status"]?.miniText ?? "").font(.caption).foregroundStyle(.secondary)
            if connection["isOwner"]?.miniTruth == true {
                if connection["shared"]?.miniTruth == true { Button("Manage Access") { grant = connection; showsGrant = true } }
                Button("Disconnect", role: .destructive) { removing = connection["id"]?.stringValue; confirmsDisconnect = true }
            }
        }
    }
    private func load() async {
        do { connections = try await api.miniAppRequest(id: app.id, resource: "connections")["items"]?.miniArray ?? [] }
        catch { self.error = error.localizedDescription }
    }
    private func disconnect() async {
        guard let removing else { return }
        do { _ = try await api.miniAppRequest(id: app.id, resource: "connections/\(removing)", method: "DELETE"); await load() }
        catch { self.error = error.localizedDescription }
    }
}

private struct MiniConnectSheet: View {
    let api: SummaryAPIClient
    let app: MiniApp
    let connector: String
    @State private var secret = ""
    @State private var shared = false
    @State private var busy = false
    @State private var error: String?
    @State private var oauth = MiniOAuthSession()
    @Environment(\.dismiss) private var dismiss
    private var definition: JSONValue { app.document.connectors[connector] ?? .null }
    private var isOAuth: Bool { definition["auth"]?["type"]?.stringValue == "oauth2" }
    var body: some View {
        NavigationStack {
            Form {
                Section("Integration") {
                    LabeledContent("Name", value: definition["title"]?.miniText ?? connector)
                    LabeledContent("Origin") { Text(definition["origin"]?.miniText ?? "").textSelection(.enabled) }
                }
                if isOAuth {
                    Section {
                        LabeledContent("Permissions", value: definition["auth"]?["scopes"]?.miniArray.map(\.miniText).joined(separator: ", ") ?? "")
                        SecureField("Client Secret", text: $secret, prompt: Text("Optional"))
                        let callback = api.baseURL.appendingPathComponent("api/v1/mini-apps/\(app.id)/connections/\(connector)/callback")
                        LabeledContent("OAuth Callback") { Text(callback.absoluteString).font(.caption).textSelection(.enabled) }
                    } header: { Text("Sign In") } footer: { Text("Sign in with the provider in your browser. Chippy stores the connection securely.") }
                } else {
                    Section {
                        SecureField("API Key", text: $secret)
                    } header: { Text("Credentials") } footer: { Text("Chippy stores the key securely. It is never included in the app itself.") }
                }
                if app.isOwner {
                    Section {
                        Toggle("Use as a Shared Connection", isOn: $shared)
                    } footer: { Text("You choose which members and operations can use it after connecting.") }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Connect API")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isOAuth ? "Sign In" : "Connect") { Task { await connect() } }.disabled(busy || (!isOAuth && secret.isEmpty)) }
            }
            .statusAlert("Connection", message: error) { error = nil }
            .interactiveDismissDisabled(busy)
        }.summarySheetSize()
    }
    private func connect() async {
        busy = true; defer { busy = false }
        do {
            var body: [String: JSONValue] = ["connector": .string(connector), "shared": .bool(shared)]
            if !secret.isEmpty { body[isOAuth ? "clientSecret" : "apiKey"] = .string(secret) }
            let result = try await api.miniAppRequest(id: app.id, resource: "connections", method: "POST", body: .object(body))
            secret = ""
            if let raw = result["authorizationUrl"]?.stringValue, let url = URL(string: raw) { try await oauth.authenticate(url) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct MiniGrantSheet: View {
    let api: SummaryAPIClient
    let app: MiniApp
    let connection: JSONValue
    @State private var email = ""
    @State private var selected: Set<String> = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var operations: [String] {
        let key = connection["connector"]?.miniText ?? ""
        return app.document.connectors[key]?["operations"]?.miniObject.keys.sorted() ?? []
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Member Email", text: $email)
                ForEach(operations, id: \.self) { operation in
                    Toggle(operation, isOn: Binding(get: { selected.contains(operation) }, set: { if $0 { selected.insert(operation) } else { selected.remove(operation) } }))
                }
                Text("Only invited app members can use this connection. Saving with no operations revokes their access.").font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Connection Access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(email.isEmpty) }
            }
            .statusAlert("Access", message: error) { error = nil }
        }.summarySheetSize()
    }
    private func save() async {
        do {
            let id = connection["id"]?.miniText ?? ""
            _ = try await api.miniAppRequest(id: app.id, resource: "connections/\(id)", method: "PUT", body: .object(["email": .string(email), "operations": .array(selected.sorted().map(JSONValue.string))]))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private final class MiniOAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func authenticate(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "summarychip") { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if callback?.host == "mini-app", URLComponents(url: callback!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "status" })?.value == "connected" { continuation.resume() }
                else { continuation.resume(throwing: URLError(.cancelled)) }
            }
            self.session = session; session.presentationContextProvider = self
            if !session.start() { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? NSWindow()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
        #endif
    }
}
