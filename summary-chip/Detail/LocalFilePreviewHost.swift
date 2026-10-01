#if DEBUG && os(iOS)
import SummaryKit
import SwiftUI

/// Exercises the production file sheet without an authenticated server session.
struct LocalFilePreviewHost: View {
    @State private var showsFile = false
    @State private var ready = false
    private let directory = FileManager.default.temporaryDirectory.appending(path: "LocalFilePreview")

    var body: some View {
        NavigationStack {
            Button("Local File") { showsFile = true }
                .disabled(!ready)
                .navigationTitle("File Preview")
        }
        .sheet(isPresented: $showsFile) {
            LocalFileSheet(summaryID: "preview", store: LocalFileStore(directory: directory.appending(path: "links")))
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--reset-local-file-preview") {
                try? FileManager.default.removeItem(at: directory)
            }
            if !FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appending(path: "Meeting.txt")
                    try Data("Meeting notes\nDecisions and next steps.".utf8).write(to: file)
                    try LocalFileStore(directory: directory.appending(path: "links"))
                        .saveCopy(of: file, filename: "Meeting.txt", summaryID: "preview")
                } catch { return }
            }
            ready = true
        }
    }
}
#endif
