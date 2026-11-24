import SummaryKit
import SwiftUI

struct ChatContextBar: View {
    let environment: AppEnvironment
    let model: ChatModel
    let summary: Summary?
    @State private var contextDocument: Summary?
    @State private var removedFileCount = 0

    private var contextDocumentID: String? {
        model.documentID
    }

    private var contextDocumentTitle: String? {
        if let target = model.resumeTarget {
            return [model.resumeCompany ?? String(localized: "Base résumé"), SummaryLanguage.displayName(for: target.language)].joined(separator: " · ")
        }
        guard let id = contextDocumentID else { return nil }
        return environment.library.items.first(where: { $0.id == id })?.title
            ?? summary?.title ?? model.trip?.title
            ?? contextDocument?.title
    }

    private var contextIcon: String {
        if model.resumeTarget != nil { return "person.text.rectangle" }
        if model.graph != nil { return "point.3.connected.trianglepath.dotted" }
        if model.trip != nil { return "map" }
        if model.miniAppID != nil { return "app.badge" }
        return "doc.text"
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.files.attachments) { file in
                    removableChip(file.filename, symbol: file.mimeType.hasPrefix("image/") ? "photo" : "doc.text") {
                        model.files.removeAttachment(file)
                        removedFileCount += 1
                    }
                }
                if contextDocumentID != nil {
                    Label {
                        Text(contextDocumentTitle ?? String(localized: "Current Document"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                    } icon: {
                        Image(systemName: contextIcon)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                    .accessibilityIdentifier("chat-context-document")
                } else {
                    Label("Chippy Library", systemImage: "books.vertical")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                        .accessibilityIdentifier("chat-context-library")
                }
                ForEach(model.graphElements) { element in
                    let symbol = switch element {
                    case .node: "circle.fill"
                    case .edge: "line.diagonal"
                    }
                    removableChip(model.graphElementLabel(element), symbol: symbol) {
                        model.graphElements.removeAll { $0 == element }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: removedFileCount)
        .sensoryFeedback(.selection, trigger: model.graphElements)
        .task(id: contextDocumentID) {
            contextDocument = nil
            guard let id = contextDocumentID, contextDocumentTitle == nil else { return }
            let document = try? await environment.api.summary(id: id)
            guard !Task.isCancelled, contextDocumentID == id else { return }
            contextDocument = document
        }
    }

    private func removableChip(_ name: String, symbol: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
                Image(systemName: "xmark").font(.caption2)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(name)")
        .help("Remove \(name)")
    }
}

struct ChatFileImporter: ViewModifier {
    let files: ChatAttachmentDraft
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .overlay { attachmentUploadOverlay }
            .fileImporter(isPresented: $isPresented, allowedContentTypes: ChatFileAttachment.contentTypes, allowsMultipleSelection: true) { result in
                do {
                    files.addFiles(try result.get())
                } catch let error as CocoaError where error.code == .userCancelled {
                    return
                } catch {
                    files.attachmentError = error.localizedDescription
                }
            }
            .statusAlert("Couldn't Attach File", message: files.attachmentError) { files.attachmentError = nil }
            .sensoryFeedback(.error, trigger: files.attachmentError) { _, error in error != nil }
            .sensoryFeedback(.success, trigger: files.attachments.count) { old, new in new > old }
    }

    @ViewBuilder private var attachmentUploadOverlay: some View {
        if let upload = files.uploadProgress {
            if upload.totalBytes > 0 {
                let fraction = min(1, Double(upload.bytesSent) / Double(upload.totalBytes))
                let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
                let bytes = upload.bytesSent.formatted(.byteCount(style: .file))
                let total = upload.totalBytes.formatted(.byteCount(style: .file))
                ActionStatusOverlay(
                    String(localized: "Uploading \(upload.filename)\n\(percent) · \(bytes) / \(total)"),
                    progress: fraction, onCancel: files.cancelAttachmentUpload
                )
            } else {
                ActionStatusOverlay(String(localized: "Preparing \(upload.filename)…"), onCancel: files.cancelAttachmentUpload)
            }
        }
    }
}
