import SummaryKit
import SwiftUI

/// Binary assets are previewed from the authenticated API, or local bytes before uploading.
struct PaperAssetView: View {
    let file: PaperFile
    var api: SummaryAPIClient?
    var paperID: String?
    var version: Int?
    var data: Data?
    @State private var downloaded: Data?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let data = data ?? downloaded {
                if file.fileExtension == "pdf" {
                    PaperPDFView(data: data)
                } else {
                    #if os(iOS)
                    if let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().padding()
                    } else { unavailable }
                    #else
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().padding()
                    } else { unavailable }
                    #endif
                }
            } else if let errorMessage {
                ContentUnavailableView("Image unavailable", systemImage: "photo", description: Text(errorMessage))
            } else { ProgressView("Loading image…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(file.name)
        .accessibilityIdentifier("paper-image-preview")
        .task(id: "\(file.asset?.key ?? ""):\(version ?? 0)") {
            guard data == nil, let api, let paperID else { return }
            downloaded = nil
            errorMessage = nil
            do { downloaded = try await api.paperImage(id: paperID, path: file.path, version: version) }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Image unavailable", systemImage: "photo")
    }
}
