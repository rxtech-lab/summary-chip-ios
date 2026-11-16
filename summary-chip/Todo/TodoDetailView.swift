import AgentMarkdownUI
import SummaryKit
import SwiftUI

struct TodoDetailView: View {
    let environment: AppEnvironment
    let id: String
    @State private var list: TodoList?
    @State private var error: String?
    @State private var status: String?
    @State private var sheet: TodoSheet?
    @State private var summary: Summary?
    @State private var feedback = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let list {
                List {
                    Section {
                        Label { Text(list.document.deadline, format: .dateTime.year().month().day().hour().minute()) }
                            icon: { Image(systemName: "calendar.badge.clock") }
                            .foregroundStyle(!list.document.isCompleted && list.document.deadline < .now ? Color.red : .secondary)
                        Text("\(list.document.items.filter(\.completed).count) of \(list.document.items.count) completed")
                            .foregroundStyle(.secondary)
                    }
                    if !list.document.description.isEmpty {
                        Section("Description") { MarkdownView(text: list.document.description, baseURL: nil) }
                    }
                    Section("Items") {
                        ForEach(list.document.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Button { toggle(item) } label: {
                                    Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(item.completed ? Color.green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(!list.isOwner || status != nil)
                                .accessibilityLabel(item.completed ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).strikethrough(item.completed)
                                    Text(item.deadline, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(!item.completed && item.deadline < .now ? Color.red : .secondary)
                                }
                            }
                        }
                    }
                }
                .refreshable { await load() }
            } else if let error {
                ContentUnavailableView { Label("Todo List Unavailable", systemImage: "checklist") }
                    description: { Text(error) } actions: { Button("Try Again") { Task { await load() } } }
            } else { ProgressView("Loading todo list…") }
        }
        .navigationTitle(list?.document.title ?? "Todo List")
        .summaryInlineNavigationTitle()
        .task(id: id) { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .toolbar {
            if list?.isOwner == true {
                ToolbarItem(placement: .primaryAction) { Button("Edit", systemImage: "pencil") { sheet = .edit } }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Share…", systemImage: "square.and.arrow.up") { open(.share) }
                    if list?.isOwner == true { Button("Delete Todo List", systemImage: "trash", role: .destructive) { open(.delete) } }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .disabled(list == nil)
            }
        }
        .sheet(item: $sheet) { target in
            switch target {
            case .edit:
                if let list { TodoEditorSheet(api: environment.api, existing: list) { self.list = $0; refreshCard() } }
            case .share:
                if let summary { ShareModeSheet(summary: summary, api: environment.api) { environment.library.upsert($0); Task { await load() } } }
            case .delete:
                if let summary { DeleteSummarySheet(api: environment.api, summary: summary) { environment.library.remove(id: id); dismiss() } }
            }
        }
        .overlay { if let status { ActionStatusOverlay(status) } }
        .statusAlert("Couldn't Update Todo List", message: list == nil ? nil : error) { error = nil }
        .sensoryFeedback(.success, trigger: feedback)
        .sensoryFeedback(.error, trigger: error)
    }
    private func load() async {
        do { list = try await environment.api.todoList(id: id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func refreshCard() {
        Task { if let updated = try? await environment.api.summary(id: id) { environment.library.upsert(updated) } }
    }
    private func toggle(_ item: TodoItem) {
        guard let list, list.isOwner, status == nil else { return }
        var document = list.document
        guard let index = document.items.firstIndex(where: { $0.id == item.id }) else { return }
        document.items[index].completed.toggle()
        status = String(localized: "Updating item…")
        Task {
            defer { status = nil }
            do {
                self.list = try await environment.api.updateTodoList(id: id, document: document, revision: list.revision)
                feedback += 1; refreshCard()
            } catch {
                self.error = error.localizedDescription
                // Keep the failed edit visible as an error, but reload so the next toggle uses the latest revision.
                self.list = (try? await environment.api.todoList(id: id)) ?? self.list
            }
        }
    }
    private func open(_ target: TodoSheet) {
        status = String(localized: "Loading…")
        Task {
            defer { status = nil }
            do { summary = try await environment.api.summary(id: id); sheet = target }
            catch { self.error = error.localizedDescription }
        }
    }
}
private enum TodoSheet: String, Identifiable { case edit, share, delete; var id: String { rawValue } }
