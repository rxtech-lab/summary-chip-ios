import Foundation
import ImageIO
import SummaryKit
import Testing
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
@testable import summary_chip

@MainActor
@Suite struct PaperImageImportTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    private var source: PaperSource {
        PaperSource(title: "Images", files: [PaperFile(path: "main.tex", content: "\\begin{document}\n\\end{document}")], mainFile: "main.tex")
    }

    @Test func unnamedProviderUsesTheActualImageFormat() async throws {
        let provider = NSItemProvider()
        provider.suggestedName = "A browser image.jpg"
        let bytes = png
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        let image: PaperImageImport = try await withCheckedThrowingContinuation { continuation in
            PaperImageImport.load(provider) { continuation.resume(with: $0) }
        }
        let file = try image.stagedFile(in: source)
        #expect(file.path == "images/A-browser-image.png")
        #expect(file.asset?.mimeType == "image/png")
        #expect(image.data == png)
    }

    @Test(arguments: [false, true]) func fileURLProviderReadsTheFileBeforeStaging(fileURLOnly: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = fileURLOnly
            ? NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
            : try #require(NSItemProvider(contentsOf: url))
        let image: PaperImageImport = try await withCheckedThrowingContinuation { continuation in
            PaperImageImport.load(provider) { continuation.resume(with: $0) }
        }
        #expect(image.data == png)
        #expect(image.fileExtension == "png")
    }

    @Test func convertsNonTeXImagesToPNG() throws {
        let input = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(input, 0, nil))
        let tiff = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        let imported = try PaperImageImport.decode(tiff as Data, filename: "photo.tiff")
        #expect(imported.fileExtension == "png")
        try PaperLimits.validateImage(path: "image.png", data: imported.data)
    }

    @Test func rejectsCorruptOversizedAndMismatchedImages() {
        #expect(throws: PaperProjectError.self) { try PaperImageImport.decode(Data("broken".utf8), filename: "photo.png") }
        #expect(throws: PaperProjectError.self) {
            try PaperImageImport.decode(Data(repeating: 0, count: PaperLimits.maxImageBytes + 1), filename: "large.png")
        }
        #expect(throws: PaperProjectError.self) { try PaperImageImport(data: png, filename: "photo.pdf", fileExtension: "pdf") }
    }

    @Test func avoidsExistingPathsAndHonorsCombinedLimit() throws {
        let image = try PaperImageImport(data: png, filename: "figure.png", fileExtension: "png")
        var project = source
        project.write(try image.stagedFile(in: project))
        project.write(PaperFile(path: "images/figure-2.png", asset: PaperAsset(key: "existing", mimeType: "image/png", byteSize: png.count)))
        #expect(try image.stagedFile(in: project).path == "images/figure-3.png")
        for index in 1...3 {
            project.write(PaperFile(path: "images/large-\(index).png", asset: PaperAsset(key: "existing", mimeType: "image/png", byteSize: PaperLimits.maxImageBytes)))
        }
        #expect(throws: PaperProjectError.self) { try image.stagedFile(in: project) }
    }

    @Test func replacementKeepsItsPathAndRequiresMatchingFormat() throws {
        let image = try PaperImageImport(data: png, filename: "new.png", fileExtension: "png")
        let old = PaperFile(path: "images/original.png", asset: PaperAsset(key: "existing", mimeType: "image/png", byteSize: png.count))
        var project = source
        project.write(old)
        #expect(try image.stagedFile(in: project, replacing: old).path == old.path)
        let pdf = PaperFile(path: "images/original.pdf", asset: PaperAsset(key: "existing", mimeType: "application/pdf", byteSize: 20))
        #expect(throws: PaperProjectError.self) { try image.stagedFile(in: project, replacing: pdf) }
    }

    #if os(macOS)
    @Test func nativeEditorRoutesImagesAndLeavesTextDropsAlone() throws {
        let view = PaperTextView.make(size: .zero)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(png, forType: .png)
        #expect(view.isImageDrop(pasteboard))
        let provider = try #require(view.imageProviders(pasteboard).first)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
        pasteboard.clearContents()
        pasteboard.setString("\\section{Text}", forType: .string)
        #expect(!view.isImageDrop(pasteboard))
        #expect(view.imageProviders(pasteboard).isEmpty)
    }
    #endif
}
