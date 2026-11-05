import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import SummaryKit

struct LocalFileTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LocalFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func importsMarkdownAsTextAndKeepsFilename() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Notes.md")
        try Data("# Meeting\n\nDecisions and next steps.".utf8).write(to: file)
        let copy = try LocalDocument.copyForReading(file)
        defer { LocalDocument.discardCopy(copy) }
        #expect(try LocalDocument.input(fileURL: copy) == .localFile(LocalFileSource(filename: "Notes.md", kind: .text, text: "# Meeting\n\nDecisions and next steps.")))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    @Test func readsExcelSheetsAsTabSeparatedRows() throws {
        let file = try LocalDocument.read(fileURL: try fixture("Budget.xlsx"))
        #expect(file.kind == .text)
        #expect(file.text == "## Q3 Budget\nItem\tCost\nCloud hosting\t\t1200.5\nTotal\tTRUE\n\n## Notes\nApproved by finance")
    }

    @Test func readsPowerPointSlidesInOrder() throws {
        let file = try LocalDocument.read(fileURL: try fixture("Roadmap.pptx"))
        #expect(file.text == "## Slide 1\nWelcome\n\n## Slide 2\nRoadmap 2026\nShip the Mac app\n\n## Slide 3\nLaunch")
    }

    @Test func readsOpenDocumentSpreadsheets() throws {
        let file = try LocalDocument.read(fileURL: try fixture("Inventory.ods"))
        #expect(file.text == "Apples\t12\nPears  green")
    }

    @Test func acceptsOfficeDocumentsForPickingAndSharing() throws {
        #expect(LocalDocument.isReadable(extension: "xlsx"))
        #expect(LocalDocument.isReadable(extension: "pptx"))
        #expect(LocalDocument.isReadable(typeIdentifier: "org.openxmlformats.spreadsheetml.sheet"))
        #expect(LocalDocument.contentTypes.contains(try #require(UTType(filenameExtension: "xlsx"))))
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appending(path: "Broken.xlsx")
        try Data("not a zip".utf8).write(to: corrupt)
        #expect(throws: LocalDocumentError.self) { try LocalDocument.read(fileURL: corrupt) }
    }

    @Test func discardingADroppedFileRemovesOnlyStagedCopies() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Dropped.md")
        try Data("# Dropped".utf8).write(to: original)
        DroppedSummaryFile(url: original, isStagedCopy: false).discard()
        #expect(FileManager.default.fileExists(atPath: original.path))
        let copy = try LocalDocument.copyForReading(original)
        DroppedSummaryFile(url: copy, isStagedCopy: true).discard()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func rejectsEmptyUnsupportedAndOversizedText() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "empty.txt")
        try Data(" \n".utf8).write(to: file)
        #expect(throws: LocalDocumentError.self) { try LocalDocument.input(fileURL: file) }
        let binary = root.appending(path: "archive.zip")
        try Data([1, 2, 3]).write(to: binary)
        #expect(throws: LocalDocumentError.self) { try LocalDocument.input(fileURL: binary) }
        try Data(String(repeating: "😀", count: 100_001).utf8).write(to: file)
        #expect(throws: LocalDocumentError.self) { try LocalDocument.input(fileURL: file) }
    }

    @Test func sharedCopySurvivesSourceDeletionAndRelaunch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.txt")
        try Data("Source contents".utf8).write(to: file)
        let store = LocalFileStore(directory: root.appending(path: "links"))
        try store.saveCopy(of: file, filename: "source.txt", summaryID: "summary/a")
        try FileManager.default.removeItem(at: file)
        let reopened = LocalFileStore(directory: root.appending(path: "links"))
        #expect(reopened.link(summaryID: "summary/a")?.isSavedCopy == true)
        #expect(try String(contentsOf: reopened.resolve(summaryID: "summary/a"), encoding: .utf8) == "Source contents")
        try reopened.remove(summaryID: "summary/a")
        #expect(reopened.link(summaryID: "summary/a") == nil)
    }

    @Test func replacingCopyWithBookmarkKeepsOriginalAndRemovesOwnedCopy() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.txt")
        try Data("Original".utf8).write(to: file)
        let store = LocalFileStore(directory: root.appending(path: "links"))
        try store.saveCopy(of: file, filename: "source.txt", summaryID: "a")
        let oldCopy = try store.resolve(summaryID: "a")
        try store.saveBookmark(LocalFileStore.bookmark(for: file), filename: "source.txt", summaryID: "a")
        #expect(store.link(summaryID: "a")?.isSavedCopy == false)
        #expect(!FileManager.default.fileExists(atPath: oldCopy.path))
        #expect(try store.resolve(summaryID: "a").standardizedFileURL == file.standardizedFileURL)
        try store.remove(summaryID: "a")
        #expect(try String(contentsOf: file, encoding: .utf8) == "Original")
    }

    @Test func failedCopyDoesNotReplaceExistingLink() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.txt")
        try Data("Original".utf8).write(to: file)
        let store = LocalFileStore(directory: root.appending(path: "links"))
        try store.saveCopy(of: file, filename: "source.txt", summaryID: "a")
        let previous = store.link(summaryID: "a")
        #expect(throws: (any Error).self) {
            try store.saveCopy(of: root.appending(path: "missing.txt"), filename: "missing.txt", summaryID: "a")
        }
        #expect(store.link(summaryID: "a") == previous)
        #expect(try String(contentsOf: store.resolve(summaryID: "a"), encoding: .utf8) == "Original")
    }

    @Test func loadsMarkdownFileRepresentationFromShareProvider() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Shared.md")
        try Data("# Shared file\nThe original contents.".utf8).write(to: file)
        let provider = NSItemProvider()
        provider.suggestedName = "Shared.md"
        provider.registerFileRepresentation(forTypeIdentifier: UTType(filenameExtension: "md")!.identifier, fileOptions: [], visibility: .all) { completion in
            completion(file, false, nil)
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        let raw = try await SharePayloadLoader.loadRaw(inputItems: [item])
        let copy = try #require(raw.localFile)
        defer { LocalDocument.discardCopy(copy) }
        #expect(copy != file)
        #expect(ShareClassifier.classify(raw) == .localFile(LocalFileSource(filename: "Shared.md", kind: .text, text: "# Shared file\nThe original contents.")))
    }

    @Test func loadsFileURLOnlyPDFProvider() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Shared.pdf")
        try writePDF("Quarterly results improved across every region.", to: file)
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier, loadHandler: { completion, _, _ in
            completion?(file as NSURL, nil)
        })
        let item = NSExtensionItem()
        item.attachments = [provider]
        let raw = try await SharePayloadLoader.loadRaw(inputItems: [item])
        let copy = try #require(raw.localFile)
        defer { LocalDocument.discardCopy(copy) }
        #expect(raw.pdfFile == nil)
        guard case .localFile(let document) = ShareClassifier.classify(raw) else {
            Issue.record("A PDF from Files is read on the device, not uploaded")
            return
        }
        #expect(document.kind == .pdf)
        #expect(document.filename == "Shared.pdf")
        #expect(document.text.contains("Quarterly results improved"))
    }

    @Test func readsPDFTextOnDeviceAndRejectsPDFsWithoutText() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Report.pdf")
        try writePDF("Lighthouse keepers trimmed lamp wicks.", to: file)
        let document = try LocalDocument.read(fileURL: file)
        #expect(document.kind == .pdf)
        #expect(document.text.contains("Lighthouse keepers"))
        let blank = root.appending(path: "Scan.pdf")
        try writePDF(nil, to: blank)
        #expect(throws: LocalDocumentError.self) { try LocalDocument.read(fileURL: blank) }
    }

    @Test func readsCodeAndStructuredTextFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, contents) in [
            ("main.swift", "print(\"hello\")"), ("app.ts", "export const a = 1"), ("config.yaml", "key: value"),
            ("data.json", "{\"a\": 1}"), ("table.csv", "a,b\n1,2"), ("Makefile", "all:\n\techo hi"),
        ] {
            let file = root.appending(path: name)
            try Data(contents.utf8).write(to: file)
            let document = try LocalDocument.read(fileURL: file)
            #expect(document.kind == .text)
            #expect(document.text == contents)
        }
        #expect(LocalDocument.isReadable(extension: "ts"))
        #expect(!LocalDocument.isReadable(extension: "zip"))
    }

    @Test func readsRichTextAsPlainText() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Letter.rtf")
        let rich = NSAttributedString(string: "Dear team, the launch moved to Friday.")
        let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: file)
        let document = try LocalDocument.read(fileURL: file)
        #expect(document.text == "Dear team, the launch moved to Friday.")
        #expect(!document.typeLabel.isEmpty)
    }

    @Test func rejectsBinaryFilesWithoutAKnownType() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appending(path: "blob.bin")
        try Data([0x89, 0x00, 0x01, 0x02, 0xFF]).write(to: binary)
        #expect(throws: LocalDocumentError.self) { try LocalDocument.read(fileURL: binary) }
        let notes = root.appending(path: "NOTES")
        try Data("Plain notes without an extension".utf8).write(to: notes)
        #expect(try LocalDocument.read(fileURL: notes).text == "Plain notes without an extension")
    }

    @Test func readsTheLinkedFileForChat() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "notes.txt")
        try Data("First draft".utf8).write(to: file)
        let store = LocalFileStore(directory: root.appending(path: "links"))
        try store.saveBookmark(LocalFileStore.bookmark(for: file), filename: "notes.txt", summaryID: "a")
        try Data("Edited after summarising".utf8).write(to: file)
        #expect(try LocalDocument.readLinked(summaryID: "a", store: store).text == "Edited after summarising")
        #expect(throws: LocalDocumentError.self) { try LocalDocument.readLinked(summaryID: "missing", store: store) }
    }

    @Test func truncatesOnCharacterBoundaries() {
        #expect(LocalDocument.prefix("ab😀c", utf16Length: 3) == "ab")
        #expect(LocalDocument.prefix("ab😀c", utf16Length: 4) == "ab😀")
        #expect(LocalDocument.prefix("abc", utf16Length: 10) == "abc")
    }

    @Test func encodesLocalSourceWithoutAnyFileReference() throws {
        let body = CreateSummaryRequest(source: .local(LocalFileSource(filename: "Notes.md", kind: .text, text: "Hello")), options: .init())
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let source = try #require(json["source"] as? [String: String])
        #expect(source == ["type": "local", "kind": "text", "text": "Hello", "filename": "Notes.md"])
    }

    @Test func recognizesImageOnlyPDF() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "scan.pdf")
        let bitmap = try #require(CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Scanned documents can be read on this device.",
            attributes: [.init(kCTFontAttributeName as String): font,
                         .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        bitmap.textPosition = CGPoint(x: 30, y: 200)
        CTLineDraw(line, bitmap)
        let image = try #require(bitmap.makeImage())
        var box = CGRect(x: 0, y: 0, width: 600, height: 200)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<5 {
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let source = try LocalDocument.read(fileURL: url)
        #expect(source.text.components(separatedBy: "Scanned documents").count == 6)
        #expect(source.kind == .pdf)
    }

    @Test func parallelPDFReadingPreservesPageOrderAndLimit() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = PDFDocument()
        for index in 0..<7 {
            let url = folder.appending(path: "\(index).pdf")
            try writePDF("Page \(index) contains unique words.", to: url)
            let source = try #require(PDFDocument(url: url))
            document.insert(try #require(source.page(at: 0)), at: index)
        }
        let full = try PDFTextReader.read(document, limit: 10_000)
        #expect(full.text.components(separatedBy: "\n\n") == (0..<7).map { "Page \($0) contains unique words." })
        let limited = try PDFTextReader.read(document, limit: 45)
        #expect(limited.text == String(full.text.prefix(45)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A one-page PDF, optionally with a line of real (selectable) text.
    private func writePDF(_ text: String?, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
    }
}
