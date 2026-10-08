import SwiftUI
import UniformTypeIdentifiers

// Native text views handle drops before their SwiftUI container. Route image drops into the
// figure sheet so file URLs or attachments never become LaTeX source, while retaining text drops.
#if os(iOS)
import UIKit

extension PlatformSourceEditor.Coordinator {
    private func isImageDrop(_ session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: PaperImageImport.dropTypes.map(\.identifier))
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        guard isImageDrop(drop.dropSession) else { return drop.suggestedProposal }
        let view = textDroppableView as? PaperUITextView
        let proposal = UITextDropProposal(operation: view?.isEditable == true && view?.onImageDrop != nil ? .copy : .forbidden)
        proposal.dropPerformer = .delegate
        proposal.dropProgressMode = .custom
        return proposal
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        guard isImageDrop(drop.dropSession), let view = textDroppableView as? PaperUITextView, view.isEditable else { return }
        _ = view.onImageDrop?(drop.dropSession.items.map(\.itemProvider))
    }
}
#elseif os(macOS)
import AppKit

extension PaperTextView {
    static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff, .pdf, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
    ]

    func isImageDrop(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: Self.imagePasteboardTypes) != nil
    }

    func imageProviders(_ pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                return NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
            }
            guard let type = item.availableType(from: Self.imagePasteboardTypes), let data = item.data(forType: type) else { return nil }
            return NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
        }
    }
}
#endif
