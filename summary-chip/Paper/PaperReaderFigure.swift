import SummaryKit
import SwiftUI

#if os(macOS)
typealias PaperPlatformImage = NSImage
#else
typealias PaperPlatformImage = UIImage
#endif

/// A figure in the reader: its images (tap one to zoom), a note for TikZ drawings, which only
/// the PDF draws, and its caption.
struct PaperFigureView: View {
    let figure: PaperFigure
    let context: PaperReaderContext

    private var size: CGFloat { context.fontSize }

    var body: some View {
        VStack(spacing: size * 0.6) {
            if figure.images.count == 1, let image = figure.images.first {
                PaperFigureImageView(image: image, context: context, caption: figure.caption)
                    .frame(maxWidth: size * 42 * CGFloat(image.width ?? 0.8))
            } else if !figure.images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size * 9), spacing: size * 0.8, alignment: .top)], spacing: size * 0.8) {
                    ForEach(Array(figure.images.enumerated()), id: \.offset) { index, image in
                        VStack(spacing: size * 0.3) {
                            PaperFigureImageView(image: image, context: context, caption: figure.caption)
                            if let caption = image.caption {
                                Text(context.text([PaperSpan.text("(\(Self.letter(index))) ")] + caption, scale: 0.85))
                                    .multilineTextAlignment(.center)
                                    .paperNotePopover(context)
                            }
                        }
                    }
                }
            }
            if figure.drawings > 0 {
                if context.renderDrawing != nil, !figure.drawingSources.isEmpty {
                    ForEach(Array(figure.drawingSources.enumerated()), id: \.offset) { _, source in
                        PaperDrawingView(source: source, context: context, caption: figure.caption)
                    }
                } else {
                    drawingNote
                }
            }
            if let caption = figure.caption {
                PaperCaption(name: figure.name, number: figure.number, caption: caption, context: context)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, size * 0.3)
        .accessibilityIdentifier("paper-reader-figure")
    }

    /// `a`, `b`, … for subfigures.
    private static func letter(_ index: Int) -> String {
        guard index < 26, let scalar = UnicodeScalar(97 + index) else { return String(index + 1) }
        return String(Character(scalar))
    }

    private var drawingNote: some View {
        VStack(spacing: size * 0.5) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: size * 1.6))
                .foregroundStyle(.secondary)
            Text(figure.drawings == 1 ? String(localized: "This diagram is drawn by LaTeX.") : String(localized: "These diagrams are drawn by LaTeX."))
                .font(context.font(0.85))
                .foregroundStyle(.secondary)
            if let showPDF = context.showPDF {
                Button("Show in PDF", systemImage: "doc.richtext", action: showPDF)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(size)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}


/// One image of a figure, loaded from the paper (PDF figures as their first page).
private struct PaperFigureImageView: View {
    let image: PaperFigure.Image
    let context: PaperReaderContext
    let caption: [PaperSpan]?
    @State private var loaded: PaperPlatformImage?
    @State private var failed = false

    private var cacheKey: String {
        "\(context.imageScope):\(image.path ?? image.requested):\(image.path.flatMap { context.assetKeys[$0] } ?? "")"
    }

    var body: some View {
        Group {
            if let loaded {
                Button {
                    context.openFigure(PaperFigureViewerItem(id: cacheKey, image: loaded, caption: caption?.plainText ?? image.requested))
                } label: {
                    platformImage(loaded)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(caption?.plainText ?? image.requested)
                .accessibilityHint("Opens the image to zoom.")
            } else if image.path == nil || failed {
                placeholder(systemImage: "photo.badge.exclamationmark", text: image.path == nil ? String(localized: "No image named “\(image.requested)”") : String(localized: "Image unavailable"))
            } else {
                placeholder(systemImage: nil, text: nil)
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private func platformImage(_ image: PaperPlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }

    private func placeholder(systemImage: String?, text: String?) -> some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.title2)
            } else {
                ProgressView()
            }
            if let text { Text(text).font(.caption).multilineTextAlignment(.center) }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: context.fontSize * 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func load() async {
        guard let path = image.path else { return }
        if let cached = PaperFigureImageCache.shared.image(for: cacheKey) {
            loaded = cached
            return
        }
        failed = false
        do {
            let data = try await context.loadImage(path)
            let isPDF = path.lowercased().hasSuffix(".pdf")
            let decoded = await Task.detached(priority: .userInitiated) { PaperFigureImageCache.decode(data, isPDF: isPDF) }.value?.image
            guard let decoded else { failed = true; return }
            PaperFigureImageCache.shared.store(decoded, for: cacheKey)
            loaded = decoded
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

/// A TikZ or pgfplots drawing, compiled by LaTeX on its own (`POST …/figures`) and shown as an
/// image that opens to zoom. When it doesn't compile, the PDF note takes its place.
private struct PaperDrawingView: View {
    let source: String
    let context: PaperReaderContext
    let caption: [PaperSpan]?
    @State private var loaded: PaperPlatformImage?
    @State private var failed = false

    private var cacheKey: String { "\(context.imageScope):drawing:\(source.hashValue)" }

    var body: some View {
        Group {
            if let loaded {
                Button {
                    context.openFigure(PaperFigureViewerItem(id: cacheKey, image: loaded, caption: caption?.plainText ?? String(localized: "Figure")))
                } label: {
                    // LaTeX draws on white: a margin of it keeps the drawing off the card's edges.
                    platformImage(loaded)
                        .resizable()
                        .scaledToFit()
                        .padding(context.fontSize * 0.9)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: min(context.fontSize * 42, max(loaded.size.width, context.fontSize * 8)))
                .accessibilityLabel(caption?.plainText ?? String(localized: "Figure"))
                .accessibilityHint("Opens the figure to zoom.")
                .accessibilityIdentifier("paper-reader-drawing")
            } else if failed {
                VStack(spacing: context.fontSize * 0.5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: context.fontSize * 1.6))
                        .foregroundStyle(.secondary)
                    Text("This diagram couldn't be drawn here.")
                        .font(context.font(0.85))
                        .foregroundStyle(.secondary)
                    if let showPDF = context.showPDF {
                        Button("Show in PDF", systemImage: "doc.richtext", action: showPDF)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(context.fontSize)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Drawing figure…").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: context.fontSize * 8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: cacheKey) { await load() }
    }

    private func platformImage(_ image: PaperPlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }

    private func load() async {
        if let cached = PaperFigureImageCache.shared.image(for: cacheKey) {
            loaded = cached
            return
        }
        guard let render = context.renderDrawing else { failed = true; return }
        failed = false
        do {
            let data = try await render(source)
            // The server answers with a PDF; previews hand over PNGs, which decode by their bytes.
            let decoded = await Task.detached(priority: .userInitiated) { PaperFigureImageCache.decode(data, isPDF: false) }.value?.image
            guard let decoded else { failed = true; return }
            PaperFigureImageCache.shared.store(decoded, for: cacheKey)
            loaded = decoded
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

/// Decoded figure images, so scrolling back or resizing the text doesn't download them again.
@MainActor
final class PaperFigureImageCache {
    static let shared = PaperFigureImageCache()
    private let cache = NSCache<NSString, PaperPlatformImage>()

    func image(for key: String) -> PaperPlatformImage? { cache.object(forKey: key as NSString) }
    func store(_ image: PaperPlatformImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    /// An image decoded off the main actor; it isn't touched again until it's handed back.
    nonisolated struct Decoded: @unchecked Sendable {
        let image: PaperPlatformImage
    }

    /// A PNG or JPEG, or a PDF's first page drawn sharp enough to zoom into.
    nonisolated static func decode(_ data: Data, isPDF: Bool) -> Decoded? {
        guard isPDF || data.starts(with: Data("%PDF-".utf8)) else { return PaperPlatformImage(data: data).map(Decoded.init) }
        // The page is drawn here rather than with `PDFPage.thumbnail`, which on iOS can place it
        // off its box and cut off the bottom of a figure.
        guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(2000 / max(box.width, box.height), 6)
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        #if os(macOS)
        return Decoded(image: NSImage(cgImage: image, size: CGSize(width: width, height: height)))
        #else
        return Decoded(image: UIImage(cgImage: image))
        #endif
    }
}

// MARK: - Viewer

struct PaperFigureViewerItem: Identifiable {
    let id: String
    let image: PaperPlatformImage
    let caption: String
}

extension View {
    /// Shows a figure full screen (a large sheet on the Mac) to zoom into.
    func paperFigureViewer(item: Binding<PaperFigureViewerItem?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { PaperFigureViewer(item: $0) }
        #else
        sheet(item: item) { PaperFigureViewer(item: $0) }
        #endif
    }
}

private struct PaperFigureViewer: View {
    let item: PaperFigureViewerItem
    @State private var zoomed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZoomableContent(label: item.caption, zoomed: $zoomed) {
            figure
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(.white)
                // Inside the zoomed content, so the layout doesn't shift as a pinch begins.
                .padding(16)
        }
        .background(.black)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            if !zoomed, !item.caption.isEmpty {
                Text(item.caption)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(20)
                    .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: zoomed)
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 960, minHeight: 540, idealHeight: 720)
        #endif
        .accessibilityIdentifier("paper-figure-viewer")
    }

    private var figure: Image {
        #if os(macOS)
        Image(nsImage: item.image)
        #else
        Image(uiImage: item.image)
        #endif
    }
}
