import Foundation
import PDFKit
import Vision

/// Recognizes bounded batches concurrently, assembling text in original page order.
enum PDFTextReader {
    static func read(_ document: PDFDocument, limit: Int, onProgress: (@Sendable (Int, Int) -> Void)? = nil) throws -> (text: String, usedOCR: Bool) {
        let pageCount = document.pageCount
        onProgress?(0, pageCount)
        var text = ""
        var usedOCR = false
        // PDFKit access and rendering stay serial; only immutable raster images cross workers.
        // A small batch bounds memory and avoids overwhelming Vision on mobile devices.
        #if os(macOS)
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        #else
        let workers = 2
        #endif
        for start in stride(from: 0, to: pageCount, by: workers) {
            try Task.checkCancellation()
            guard text.utf16.count < limit else { break }
            let end = min(start + workers, pageCount)
            let pages = try (start..<end).map { index in
                try autoreleasepool { try prepare(document.page(at: index)) }
            }
            let batch = RecognitionBatch(count: pages.count)
            DispatchQueue.concurrentPerform(iterations: pages.count) { offset in
                let result = Result { try autoreleasepool { try recognize(pages[offset]) } }
                batch.record(result, at: offset) { completed in
                    onProgress?(start + completed, pageCount)
                }
            }
            try Task.checkCancellation()
            for (offset, result) in batch.results.enumerated() {
                let pageText = try result!.get()
                usedOCR = usedOCR || pages[offset].image != nil
                guard text.utf16.count < limit else { break }
                let separator = text.isEmpty ? "" : "\n\n"
                text += LocalDocument.prefix(separator + pageText, utf16Length: limit - text.utf16.count)
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), usedOCR)
    }

    /// CGImage is immutable; no PDFKit objects are shared with recognition workers.
    private struct PreparedPage: @unchecked Sendable {
        let text: String
        let image: CGImage?
    }

    /// Workers serialize result writes and progress callbacks; results are read after the join.
    private final class RecognitionBatch: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = 0
        private(set) var results: [Result<String, Error>?]
        init(count: Int) { results = Array(repeating: nil, count: count) }
        func record(_ result: Result<String, Error>, at index: Int, progress: (Int) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            results[index] = result
            completed += 1
            progress(completed)
        }
    }

    private static func prepare(_ page: PDFPage?) throws -> PreparedPage {
        guard let page else { throw LocalDocumentError.unsupported }
        let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !embedded.isEmpty { return PreparedPage(text: embedded, image: nil) }
        guard let pdfPage = page.pageRef else { throw LocalDocumentError.unsupported }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return PreparedPage(text: "", image: nil) }
        let scale = min(3, 2400 / max(bounds.width, bounds.height))
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw LocalDocumentError.unsupported }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.concatenate(pdfPage.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pdfPage)
        guard let image = context.makeImage() else { throw LocalDocumentError.unsupported }
        return PreparedPage(text: "", image: image)
    }

    private static func recognize(_ page: PreparedPage) throws -> String {
        guard let image = page.image else { return page.text }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func uploadText(at url: URL, onProgress: (@Sendable (Int, Int) -> Void)? = nil) throws -> String? {
        guard let document = PDFDocument(url: url) else { throw LocalDocumentError.unsupported }
        let result = try read(document, limit: LocalDocument.maxTextLength, onProgress: onProgress)
        guard !result.text.isEmpty else { throw LocalDocumentError.noPDFText }
        return result.usedOCR ? result.text : nil
    }
}
