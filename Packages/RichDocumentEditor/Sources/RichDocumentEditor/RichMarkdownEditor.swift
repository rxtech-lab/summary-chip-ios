import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A reusable Markdown composer. The host authenticates, creates a signed upload, and finalizes
/// it through its WebP compressor. No image bytes are sent through the application API.
public struct RichMarkdownEditor: View {
    public typealias Upload = @MainActor (Data, String, String, @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
    @Binding private var markdown: String
    private let upload: Upload
    private let onUploadingChanged: (Bool) -> Void
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var uploading = false
    @State private var sent: Int64 = 0
    @State private var total: Int64 = 0
    @State private var error: String?
    @State private var feedback = 0

    public init(markdown: Binding<String>, onUploadingChanged: @escaping (Bool) -> Void = { _ in }, upload: @escaping Upload) {
        _markdown = markdown
        self.upload = upload
        self.onUploadingChanged = onUploadingChanged
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
                Button { importing = true } label: { Label("File", systemImage: "folder") }
                Button { pasteImage() } label: { Label("Paste Image", systemImage: "clipboard") }
                Spacer()
                Menu {
                    Button("Heading") { markdown += "\n\n## Heading\n" }
                    Button("Bold") { markdown += " **bold**" }
                    Button("List") { markdown += "\n- Item\n" }
                    Button("Link") { markdown += " [title](https://example.com)" }
                } label: { Label("Format", systemImage: "textformat") }
            }
            .labelStyle(.iconOnly)
            .padding(12)
            Divider()
            #if canImport(UIKit)
            PasteTextEditor(text: $markdown) { data in addImage(data, mime: "image/png") }
            #else
            TextEditor(text: $markdown)
                .font(.system(.body, design: .monospaced))
                .onPasteCommand(of: [.image]) { providers in
                    guard let provider = providers.first, let type = provider.registeredTypeIdentifiers.first else { return }
                    _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in addImage(data, mime: UTType(type)?.preferredMIMEType ?? "image/png") }
                    }
                }
            #endif
        }
        .frame(minHeight: 260)
        .disabled(uploading)
        .overlay {
            if uploading {
                VStack(spacing: 12) {
                    ProgressView(value: Double(sent), total: Double(max(total, 1)))
                    Text(sent == total && total > 0 ? "Compressing image to WebP…" : "Uploading image…")
                    Text("\(Int(Double(sent) / Double(max(total, 1)) * 100))% · \(sent.formatted(.byteCount(style: .file))) / \(total.formatted(.byteCount(style: .file)))")
                        .font(.caption).monospacedDigit()
                }
                .padding(24).frame(maxWidth: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                guard (values.fileSize ?? 0) <= 15 * 1024 * 1024 else { throw ImageError.tooLarge }
                addImage(try Data(contentsOf: url), mime: values.contentType?.preferredMIMEType ?? "image/png")
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: photo) { _, selected in
            guard let selected else { return }
            Task {
                do {
                    guard let data = try await selected.loadTransferable(type: Data.self) else { throw ImageError.unreadable }
                    addImage(data, mime: selected.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg")
                } catch { self.error = error.localizedDescription }
                photo = nil
            }
        }
        .alert("Image Upload Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .sensoryFeedback(.success, trigger: feedback)
        .sensoryFeedback(.error, trigger: error)
        .interactiveDismissDisabled(uploading)
        .onChange(of: uploading) { _, value in onUploadingChanged(value) }
    }

    private func pasteImage() {
        #if canImport(UIKit)
        if let data = UIPasteboard.general.image?.pngData() { addImage(data, mime: "image/png"); return }
        #elseif canImport(AppKit)
        if let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) {
            addImage(data, mime: "image/png"); return
        }
        #endif
        error = "Copy an image first."
    }

    private func addImage(_ data: Data, mime: String) {
        guard !uploading else { return }
        guard data.count <= 15 * 1024 * 1024 else { error = ImageError.tooLarge.localizedDescription; return }
        uploading = true; sent = 0; total = Int64(data.count)
        Task {
            defer { uploading = false }
            do {
                let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "png"
                let url = try await upload(data, "image.\(ext)", mime) { sent, total in
                    Task { @MainActor in self.sent = sent; self.total = total }
                }
                markdown += "\n\n![Image](\(url.absoluteString))\n"
                feedback += 1
            } catch { self.error = error.localizedDescription }
        }
    }
}

private enum ImageError: LocalizedError {
    case tooLarge, unreadable
    var errorDescription: String? { self == .tooLarge ? "Images must be 15 MB or smaller." : "The image could not be read." }
}

#if canImport(UIKit)
/// Intercepts the native Paste action, including the keyboard shortcut and edit menu.
private struct PasteTextEditor: UIViewRepresentable {
    @Binding var text: String
    let image: (Data) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ImagePasteTextView {
        let view = ImagePasteTextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.backgroundColor = .clear
        view.text = text
        view.image = image
        return view
    }
    func updateUIView(_ view: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.image = image
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteTextEditor
        init(_ parent: PasteTextEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
private final class ImagePasteTextView: UITextView {
    var image: ((Data) -> Void)?
    override func paste(_ sender: Any?) {
        if let data = UIPasteboard.general.image?.pngData() { image?(data) }
        else { super.paste(sender) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif
