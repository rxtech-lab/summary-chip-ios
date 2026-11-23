#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import RichDocumentEditor

@MainActor
struct ComposerPasteTests {
    @Test func shiftReturnInsertsALineAndReturnSubmits() throws {
        _ = NSApplication.shared
        var text = "First"
        var submitted: [String] = []
        let content = ComposerTextView(
            "Title", text: Binding(get: { text }, set: { text = $0 }), isFocused: .constant(false),
            onSubmit: { submitted.append(text) }, onPasteAttachments: { _ in }
        )
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(composer(in: host))
        #expect(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 5, length: 0))

        func returnKey(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        }
        view.keyDown(with: try returnKey(modifiers: .shift))
        #expect(text == "First\n")
        #expect(submitted.isEmpty)
        view.insertText("Second", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: try returnKey(modifiers: []))
        #expect(submitted == ["First\nSecond"])
        #expect(text == "First\nSecond")
    }

    private func composer(in view: NSView) -> ComposerNSTextView? {
        if let composer = view as? ComposerNSTextView { return composer }
        return view.subviews.lazy.compactMap { composer(in: $0) }.first
    }

    @Test func finderFileAndImageArriveAsAttachments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Notes.txt")
        let fileData = Data("hello".utf8)
        try fileData.write(to: fileURL)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSPasteboardItem()
        // Some applications also advertise a URL when copying an image.
        image.setString("https://example.com", forType: .string)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        image.setData(png, forType: .png)
        #expect(board.writeObjects([fileURL as NSURL, image]))

        let view = ComposerNSTextView()
        var files: [PastedAttachment] = []
        view.onPasteAttachments = { files = $0 }
        #expect(view.pasteContent(from: board))
        #expect(files.map(\.filename) == ["Notes.txt", "Pasted Image.png"])
        #expect(files.map(\.mimeType) == ["text/plain", "image/png"])
        #expect(files.map(\.data) == [fileData, png])
    }

    @Test func multilineListPasteAppliesOnlyToAnEmptyComposer() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("First\n\n  Second\n", forType: .string)
        let view = ComposerNSTextView()
        var pasted: [String] = []
        view.onPasteLines = { pasted = $0 }
        #expect(view.pasteContent(from: board))
        #expect(pasted == ["First", "Second"])

        view.string = "Draft"
        #expect(!view.pasteContent(from: board))
    }
}
#endif
