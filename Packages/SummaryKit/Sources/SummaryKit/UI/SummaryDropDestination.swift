#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// A file dropped on or opened into the app, handed to `SummaryCreationFlow(initialFile:)`.
public struct DroppedSummaryFile: Sendable, Hashable {
    public let url: URL
    /// A staged copy the app owns (iOS lends dropped files only during the drop) rather than
    /// the user's original, which is bookmarked instead.
    public let isStagedCopy: Bool

    public init(url: URL, isStagedCopy: Bool) {
        self.url = url
        self.isStagedCopy = isStagedCopy
    }

    /// Removes a staged copy that will no longer be summarised; originals are left alone.
    public func discard() {
        if isStagedCopy { LocalDocument.discardCopy(url) }
    }
}

extension View {
    /// Accepts a dropped PDF, text or Markdown file, and on macOS a dropped web link.
    /// Only the first item of a multi-item drop is used.
    public func summaryDropDestination(
        isEnabled: Bool = true,
        isTargeted: @escaping (Bool) -> Void,
        onFile: @escaping (DroppedSummaryFile) -> Void,
        onLink: @escaping (URL) -> Void = { _ in }
    ) -> some View {
        #if os(macOS)
        dropDestination(for: URL.self) { urls, _ in
            guard isEnabled, let url = urls.first else { return false }
            if url.isFileURL {
                onFile(DroppedSummaryFile(url: url, isStagedCopy: false))
            } else {
                onLink(url)
            }
            return true
        } isTargeted: { isTargeted(isEnabled && $0) }
        #else
        dropDestination(for: DroppedLocalFile.self) { files, _ in
            guard isEnabled, let file = files.first else {
                files.forEach { LocalDocument.discardCopy($0.url) }
                return false
            }
            files.dropFirst().forEach { LocalDocument.discardCopy($0.url) }
            onFile(DroppedSummaryFile(url: file.url, isStagedCopy: true))
            return true
        } isTargeted: { isTargeted(isEnabled && $0) }
        #endif
    }
}

/// The dashed "Drop to summarise" highlight shown while a drop hovers over a target.
public struct SummaryDropHighlight: View {
    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .overlay { Label("Drop to summarise", systemImage: "doc.badge.plus").font(.headline) }
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityIdentifier("summary-drop-highlight")
    }
}

#if os(iOS)
/// A file dropped from Files or another app. iOS lends it only during the drop, so it's staged.
struct DroppedLocalFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .pdf, importing: stage)
        FileRepresentation(importedContentType: UTType(filenameExtension: "md") ?? .plainText, importing: stage)
        FileRepresentation(importedContentType: .plainText, importing: stage)
    }

    private static func stage(_ received: ReceivedTransferredFile) throws -> DroppedLocalFile {
        DroppedLocalFile(url: try LocalDocument.copyForReading(received.file))
    }
}
#endif
#endif
