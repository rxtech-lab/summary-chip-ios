import QuickLook
import SummaryKit
import SwiftUI

/// A dedicated screen for the device-local source association and its actions.
struct LocalFileSheet: View {
    let summaryID: String
    let store: LocalFileStore
    @Environment(\.dismiss) private var dismiss
    @State private var link: LocalFileLink?
    @State private var isPicking = false
    @State private var isWorking = false
    @State private var status: String?
    @State private var changedCount = 0
    @State private var failedCount = 0
    @State private var preview: URL?
    @State private var previewCopy: URL?
    @State private var path = NavigationPath()

    private struct RemoveRoute: Hashable {}

    init(summaryID: String, store: LocalFileStore = LocalFileStore()) {
        self.summaryID = summaryID
        self.store = store
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    if let link {
                        Label(link.filename, systemImage: "doc")
                        Button {
                            openFile()
                        } label: { Label("Open file", systemImage: "doc.text.magnifyingglass") }
                        .accessibilityIdentifier("open-local-file")
                    } else {
                        ContentUnavailableView("No local file linked", systemImage: "doc.badge.plus",
                            description: Text("Choose the original file to keep it with this summary. Chat reads it on this device to answer questions."))
                    }
                } footer: {
                    Text(link?.isSavedCopy == true
                        ? "This is a saved copy of the shared file. Link the original from Files if you want to open the latest version."
                        : "This link is saved on this device. Chat reads the latest version of the file; changing it does not regenerate the summary.")
                }
                Section {
                    Button { isPicking = true } label: {
                        Label(link == nil ? "Link a file…" : "Replace file link…", systemImage: "link.badge.plus")
                    }
                    .accessibilityIdentifier("link-local-file")
                    if link != nil {
                        NavigationLink(value: RemoveRoute()) {
                            Label("Remove file link…", systemImage: "trash").foregroundStyle(.red)
                        }
                        .accessibilityIdentifier("remove-local-file")
                    }
                } footer: {
                    Text("Local files stay on this device. Their content isn’t stored with your summary or included in shared links.")
                }
            }
            .navigationTitle("Local File")
            .summaryInlineNavigationTitle()
            .navigationDestination(for: RemoveRoute.self) { _ in
                Form {
                    Section {
                        Text(link?.filename ?? "Local file").font(.headline)
                        Text("Remove the association with this summary and any saved copy. The original file in Files and the summary are kept.")
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button(role: .destructive) { removeLink() } label: {
                            Label("Remove file link", systemImage: "trash")
                        }
                        .accessibilityIdentifier("confirm-remove-local-file")
                    }
                }
                .navigationTitle("Remove File Link")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .disabled(isWorking)
        .overlay {
            if isWorking { ActionStatusOverlay("Opening file…", isWorking: true) }
        }
        .statusAlert("Local File", message: status) { status = nil }
        .sensoryFeedback(.success, trigger: changedCount)
        .sensoryFeedback(.error, trigger: failedCount)
        .interactiveDismissDisabled(isWorking)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: LocalDocument.contentTypes) { result in
            linkFile(result)
        }
        .quickLookPreview($preview)
        .onChange(of: preview) { _, new in
            if new == nil { cleanPreview() }
        }
        .onAppear { link = store.link(summaryID: summaryID) }
        .onDisappear { cleanPreview() }
    }

    private func linkFile(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                fail(error)
            }
            return
        }
        perform(message: "File linked.") {
            try store.saveBookmark(LocalFileStore.bookmark(for: url), filename: url.lastPathComponent, summaryID: summaryID)
        }
    }

    private func removeLink() {
        perform(message: "File link removed.") { try store.remove(summaryID: summaryID) }
        if link == nil { path = NavigationPath() }
    }

    private func perform(message: String, action: () throws -> Void) {
        do {
            try action()
            link = store.link(summaryID: summaryID)
            status = message
            changedCount += 1
        } catch { fail(error) }
    }

    private func fail(_ error: any Error) {
        status = error.localizedDescription
        failedCount += 1
    }

    private func openFile() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let url = try store.resolve(summaryID: summaryID)
                let filename = link?.filename
                let copy = try await Task.detached { try LocalDocument.copyForReading(url, filename: filename) }.value
                cleanPreview()
                previewCopy = copy
                preview = copy
            } catch { fail(error) }
        }
    }

    private func cleanPreview() {
        if let previewCopy { LocalDocument.discardCopy(previewCopy) }
        previewCopy = nil
    }
}
