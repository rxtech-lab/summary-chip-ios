import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A file or image pasted (or picked) into a composer, ready for a direct signed upload.
public struct PastedAttachment: Sendable, Identifiable {
    public let id = UUID()
    public var data: Data
    public var filename: String
    public var mimeType: String
    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
    public var isImage: Bool { mimeType.hasPrefix("image/") }

    /// Reads a picked or pasted file URL. Formats the server can't decode (HEIC…) become JPEG.
    public static func load(fileURL url: URL) throws -> PastedAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
        return normalized(data: try Data(contentsOf: url, options: .mappedIfSafe), filename: url.lastPathComponent, type: type)
    }

    public static func normalized(data: Data, filename: String, type: UTType) -> PastedAttachment {
        let webSafe: [UTType] = [.jpeg, .png, .gif, .webP]
        if type.conforms(to: .image), !webSafe.contains(where: type.conforms(to:)), let jpeg = jpegData(from: data) {
            let base = (filename as NSString).deletingPathExtension
            return PastedAttachment(data: jpeg, filename: (base.isEmpty ? "Image" : base) + ".jpg", mimeType: "image/jpeg")
        }
        return PastedAttachment(data: data, filename: filename, mimeType: type.preferredMIMEType ?? "application/octet-stream")
    }

    private static func jpegData(from data: Data) -> Data? {
        #if canImport(UIKit)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.9)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        #else
        return nil
        #endif
    }

}

private func pastedLines(in text: String?) -> [String]? {
    guard let text, text.contains(where: \.isNewline) else { return nil }
    let lines = text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return lines.count > 1 ? lines : nil
}

/// A borderless, auto-growing multi-line field. Return submits, Shift+Return inserts a new line,
/// and pasting images or files hands them to `onPasteAttachments` instead of inserting text.
public struct ComposerTextView: View {
    @Binding private var text: String
    @Binding private var isFocused: Bool
    private let placeholder: LocalizedStringKey
    private let identifier: String?
    private let onSubmit: () -> Void
    private let onPasteAttachments: ([PastedAttachment]) -> Void
    private let onPasteError: (String) -> Void
    private let onPasteLines: (([String]) -> Void)?
    private let onLoadingAttachments: (Bool) -> Void

    public init(_ placeholder: LocalizedStringKey, text: Binding<String>, isFocused: Binding<Bool>,
                accessibilityIdentifier: String? = nil,
                onSubmit: @escaping () -> Void,
                onPasteAttachments: @escaping ([PastedAttachment]) -> Void,
                onPasteError: @escaping (String) -> Void = { _ in },
                onPasteLines: (([String]) -> Void)? = nil,
                onLoadingAttachments: @escaping (Bool) -> Void = { _ in }) {
        self.placeholder = placeholder
        _text = text
        _isFocused = isFocused
        self.identifier = accessibilityIdentifier
        self.onSubmit = onSubmit
        self.onPasteAttachments = onPasteAttachments
        self.onPasteError = onPasteError
        self.onPasteLines = onPasteLines
        self.onLoadingAttachments = onLoadingAttachments
    }

    public var body: some View {
        PlatformComposer(text: $text, isFocused: $isFocused, identifier: identifier,
                         onSubmit: onSubmit, onPasteAttachments: onPasteAttachments,
                         onPasteError: onPasteError, onPasteLines: onPasteLines,
                         onLoadingAttachments: onLoadingAttachments)
            .accessibilityLabel(Text(placeholder))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

#if canImport(UIKit)
private struct PlatformComposer: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let identifier: String?
    let onSubmit: () -> Void
    let onPasteAttachments: ([PastedAttachment]) -> Void
    let onPasteError: (String) -> Void
    let onPasteLines: (([String]) -> Void)?
    let onLoadingAttachments: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .done
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        return view
    }
    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityIdentifier = identifier
        view.onPasteAttachments = onPasteAttachments
        view.onPasteError = onPasteError
        view.onPasteLines = onPasteLines
        view.onLoadingAttachments = onLoadingAttachments
        if view.text != text { view.text = text }
        if isFocused != view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator, view.window != nil else { return }
                if coordinator.parent.isFocused { view.becomeFirstResponder() }
                else if view.isFirstResponder { view.resignFirstResponder() }
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(size.height, uiView.font?.lineHeight ?? 20))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlatformComposer
        init(_ parent: PlatformComposer) { self.parent = parent }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil,
                  let view = textView as? ComposerUITextView, !view.isInsertingNewline else { return true }
            parent.onSubmit()
            return false
        }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.isFocused { parent.isFocused = true } }
        func textViewDidEndEditing(_ textView: UITextView) { if parent.isFocused { parent.isFocused = false } }
    }
}

final class ComposerUITextView: UITextView {
    var onPasteAttachments: (([PastedAttachment]) -> Void)?
    var onPasteError: ((String) -> Void)?
    var onPasteLines: (([String]) -> Void)?
    var onLoadingAttachments: ((Bool) -> Void)?
    private(set) var isInsertingNewline = false

    override var keyCommands: [UIKeyCommand]? {
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(shiftReturn(_:)))
        newline.wantsPriorityOverSystemBehavior = true
        return [newline] + (super.keyCommands ?? [])
    }
    @objc private func shiftReturn(_ sender: UIKeyCommand) {
        guard let selection = selectedTextRange else { return }
        isInsertingNewline = true
        defer { isInsertingNewline = false }
        replace(selection, withText: "\n")
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(shiftReturn(_:)) { return isEditable && markedTextRange == nil }
        if action == #selector(paste(_:)), UIPasteboard.general.itemProviders.contains(where: {
            Self.attachmentType(for: $0) != nil
        }) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        let files = board.itemProviders.compactMap { provider in
            Self.attachmentType(for: provider).map { (provider, $0) }
        }
        if !files.isEmpty, let onPasteAttachments {
            let reportError = onPasteError
            let loading = onLoadingAttachments
            loading?(true)
            Task {
                defer { loading?(false) }
                var loaded: [PastedAttachment] = []
                for (provider, type) in files {
                    do { loaded.append(try await Self.load(provider, type: type)) }
                    catch { reportError?(error.localizedDescription) }
                }
                if !loaded.isEmpty { onPasteAttachments(loaded) }
            }
        } else if text.isEmpty, let onPasteLines, let lines = pastedLines(in: board.string) {
            onPasteLines(lines)
        } else {
            super.paste(sender)
        }
    }

    private static func attachmentType(for provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        if types.contains(.fileURL) { return .fileURL }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return image }
        let hasFilename = provider.suggestedName.map { !($0 as NSString).pathExtension.isEmpty } ?? false
        if !hasFilename, types.contains(where: { $0.conforms(to: .text) || $0.conforms(to: .url) }) {
            // Copied text can also advertise HTML, RTF, or an opaque data representation.
            return nil
        }
        return types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
    }

    private static func load(_ provider: NSItemProvider, type: UTType) async throws -> PastedAttachment {
        if type == .fileURL {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                    let url: URL?
                    switch item {
                    case let file as URL: url = file
                    case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                    case let string as String: url = URL(string: string)
                    default: url = nil
                    }
                    guard let url, url.isFileURL else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                        return
                    }
                    continuation.resume(with: Result { try PastedAttachment.load(fileURL: url) })
                }
            }
        }
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { fileURL, error in
                guard let fileURL else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                // Read before returning. The system removes the temporary file after this callback.
                let name = suggestedName ?? fileURL.lastPathComponent
                var filename = name
                if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                    filename += "." + ext
                }
                continuation.resume(with: Result {
                    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    return PastedAttachment.normalized(data: data, filename: filename, type: type)
                })
            }
        }
    }
}
#elseif canImport(AppKit)
private struct PlatformComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let identifier: String?
    let onSubmit: () -> Void
    let onPasteAttachments: ([PastedAttachment]) -> Void
    let onPasteError: (String) -> Void
    let onPasteLines: (([String]) -> Void)?
    let onLoadingAttachments: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ComposerNSTextView {
        let view = ComposerNSTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.focusRingType = .none
        view.string = text
        return view
    }
    func updateNSView(_ view: ComposerNSTextView, context: Context) {
        context.coordinator.parent = self
        view.setAccessibilityIdentifier(identifier)
        view.onPasteAttachments = onPasteAttachments
        view.onPasteError = onPasteError
        view.onPasteLines = onPasteLines
        view.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusChanged(focused) }
        if view.string != text { view.string = text }
        view.wantsFocus = isFocused
        let focused = view.window?.firstResponder === view
        if isFocused != focused {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                if view.wantsFocus { window.makeFirstResponder(view) }
                else if window.firstResponder === view { window.makeFirstResponder(nil) }
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: nsView.font ?? .preferredFont(forTextStyle: .body))
        return CGSize(width: width, height: ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY, lineHeight)))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlatformComposer
        init(_ parent: PlatformComposer) { self.parent = parent }
        func focusChanged(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onPasteAttachments: (([PastedAttachment]) -> Void)?
    var onPasteError: ((String) -> Void)?
    var onPasteLines: (([String]) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var wantsFocus = false

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let layout = layoutManager else { return super.intrinsicContentSize }
        layout.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(layout.usedRect(for: container).height))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus {
            DispatchQueue.main.async { [weak self] in
                if let self, wantsFocus { window?.makeFirstResponder(self) }
            }
        }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        // AppKit key bindings can map both Return and Shift-Return to insertNewline:.
        let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
        if event.charactersIgnoringModifiers == "\r", modifiers == .shift, !hasMarkedText() {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .pdf] + super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        if !pasteContent(from: .general) { super.paste(sender) }
    }

    func pasteContent(from board: NSPasteboard) -> Bool {
        var loaded: [PastedAttachment] = []
        var handled = false
        for item in board.pasteboardItems ?? [] {
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                handled = true
                do { loaded.append(try PastedAttachment.load(fileURL: url)) }
                catch { onPasteError?(error.localizedDescription) }
            } else if let type = item.availableType(from: [.png, .tiff, .pdf]), let data = item.data(forType: type),
                      let contentType = UTType(type.rawValue) {
                handled = true
                let name = contentType == .pdf ? "Pasted File" : "Pasted Image"
                let filename = name + "." + (contentType.preferredFilenameExtension ?? "bin")
                loaded.append(.normalized(data: data, filename: filename, type: contentType))
            }
        }
        if !loaded.isEmpty { onPasteAttachments?(loaded) }
        if !handled, string.isEmpty, let onPasteLines, let lines = pastedLines(in: board.string(forType: .string)) {
            onPasteLines(lines)
            return true
        }
        return handled
    }
}
#endif
