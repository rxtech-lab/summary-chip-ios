#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import RichDocumentEditor

@MainActor
struct ComposerKeyboardTests {
    @Test func shiftReturnReplacesSelectionAndReturnSubmits() throws {
        var text = "First Second"
        var submitted: [String] = []
        let host = UIHostingController(rootView: ComposerTextView(
            "Title", text: Binding(get: { text }, set: { text = $0 }), isFocused: .constant(false),
            onSubmit: { submitted.append(text) }, onPasteAttachments: { _ in }
        ))
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        host.view.layoutIfNeeded()
        let view = try #require(composer(in: host.view))
        view.selectedRange = NSRange(location: 5, length: 1)

        let command = try #require(view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .shift })
        #expect(view.canPerformAction(command.action, withSender: command))
        #expect(UIApplication.shared.sendAction(command.action, to: view, from: command, for: nil))
        #expect(view.text == "First\nSecond")
        #expect(text == "First\nSecond")
        #expect(submitted.isEmpty)

        let shouldInsert = view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: "\n")
        #expect(shouldInsert == false)
        #expect(submitted == ["First\nSecond"])
    }

    private func composer(in view: UIView) -> ComposerUITextView? {
        if let composer = view as? ComposerUITextView { return composer }
        return view.subviews.lazy.compactMap { composer(in: $0) }.first
    }
}
#endif
