import SummaryKit
import SwiftUI

/// Which photo of a set the reader opened full screen.
struct TripPhotoViewerItem: Identifiable {
    let photos: [TripPhoto]
    let start: Int
    var id: Int { start }
}

extension View {
    /// Shows `item`'s photos full screen (a large sheet on the Mac) to page through and zoom.
    func tripPhotoViewer(item: Binding<TripPhotoViewerItem?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { TripPhotoViewer(photos: $0.photos, start: $0.start) }
        #else
        sheet(item: item) { TripPhotoViewer(photos: $0.photos, start: $0.start) }
        #endif
    }
}

/// Photos on black, one page each: pinch or double-tap to zoom, drag to pan while zoomed,
/// swipe between photos when not.
struct TripPhotoViewer: View {
    let photos: [TripPhoto]
    private let start: Int
    @State private var page: Int?
    @State private var zoomed = false
    @Environment(\.dismiss) private var dismiss

    init(photos: [TripPhoto], start: Int) {
        self.photos = photos
        self.start = min(max(0, start), max(0, photos.count - 1))
        _page = State(initialValue: self.start)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos.indices, id: \.self) { index in
                    ZoomableContent(label: photos[index].caption ?? String(localized: "Photo"), zoomed: page == index ? $zoomed : .constant(false)) {
                        // Fitted, not cropped, so the whole photo shows before zooming in.
                        SummaryRemoteImage(url: photos[index].imageURL) {
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                        }
                        .scaledToFit()
                    }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .defaultScrollAnchor(UnitPoint(x: photos.count > 1 ? CGFloat(start) / CGFloat(photos.count - 1) : 0, y: 0), for: .initialOffset)
        .scrollIndicators(.hidden)
        .scrollDisabled(zoomed)
        .background(.black)
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay(alignment: .bottom) { caption }
        .onChange(of: page) { zoomed = false }
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.impact(weight: .light), trigger: zoomed)
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 960, minHeight: 540, idealHeight: 720)
        #endif
        .accessibilityIdentifier("trip-photo-viewer")
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
        .padding(16)
    }

    @ViewBuilder
    private var caption: some View {
        let photo = photos.indices.contains(page ?? 0) ? photos[page ?? 0] : nil
        let text = [photo?.caption?.nilIfBlank, photo?.credit?.nilIfBlank].compactMap(\.self).joined(separator: " · ")
        let counter = photos.count > 1 ? "\((page ?? 0) + 1) / \(photos.count)" : nil
        if !zoomed, !text.isEmpty || counter != nil {
            VStack(spacing: 4) {
                if !text.isEmpty {
                    Text(text).font(.footnote).multilineTextAlignment(.center)
                }
                if let counter {
                    Text(counter).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(20)
            .allowsHitTesting(false)
        }
    }
}

/// A photo or figure fitted to the screen, zoomable from 1× to 5×: pinch (around the fingers)
/// or double-tap to zoom, drag to pan while zoomed.
struct ZoomableContent<Content: View>: View {
    let label: String
    @Binding var zoomed: Bool
    @ViewBuilder let content: Content

    fileprivate static var maxScale: CGFloat { 5 }
    fileprivate static var doubleTapScale: CGFloat { 2.5 }

    #if os(iOS)
    @State private var controller = ZoomController()

    var body: some View {
        ZoomScrollView(zoomed: $zoomed, controller: controller, content: content)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
            .accessibilityZoomAction { action in
                controller.zoom(by: action.direction == .zoomIn ? 2 : 0.5)
            }
    }
    #else
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// The scale and offset when the current pinch or drag began.
    @State private var start: (scale: CGFloat, offset: CGSize)?

    var body: some View {
        GeometryReader { proxy in
            // The gestures sit on this untransformed container, so their locations stay in
            // screen space while the content underneath scales and moves.
            ZStack {
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(magnify(in: proxy.size).simultaneously(with: pan(in: proxy.size)))
            .onTapGesture(count: 2) { location in
                withAnimation(.snappy) { toggleZoom(at: location, in: proxy.size) }
            }
            .overlay(alignment: .bottomTrailing) { zoomButtons(in: proxy.size) }
        }
        .clipped()
        .onChange(of: zoomed) { _, isZoomed in
            if !isZoomed, scale != 1 { withAnimation(.snappy) { reset() } }
        }
        .accessibilityLabel(label)
        .accessibilityZoomAction { action in
            withAnimation(.snappy) { setScale(action.direction == .zoomIn ? scale * 2 : scale / 2, anchor: nil, in: nil) }
        }
    }

    /// Zooms around the point between the fingers, so it stays under them.
    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let begin = start ?? (scale, offset)
                start = begin
                let target = min(max(begin.scale * value.magnification, 0.8), Self.maxScale * 1.2)
                let anchor = CGPoint(x: value.startLocation.x - size.width / 2, y: value.startLocation.y - size.height / 2)
                let ratio = target / begin.scale
                scale = target
                offset = CGSize(
                    width: anchor.x - (anchor.x - begin.offset.width) * ratio,
                    height: anchor.y - (anchor.y - begin.offset.height) * ratio
                )
            }
            .onEnded { _ in
                start = nil
                withAnimation(.snappy) { setScale(scale, anchor: nil, in: size) }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard scale > 1 else { return }
                let begin = start ?? (scale, offset)
                start = begin
                offset = CGSize(width: begin.offset.width + value.translation.width, height: begin.offset.height + value.translation.height)
            }
            .onEnded { _ in
                start = nil
                withAnimation(.snappy) { offset = clamped(offset, scale: scale, in: size) }
            }
    }

    /// Mice can't pinch, so the Mac gets buttons too.
    private func zoomButtons(in size: CGSize) -> some View {
        HStack(spacing: 8) {
            Button { withAnimation(.snappy) { setScale(scale / 1.5, anchor: nil, in: size) } } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale <= 1)
                .accessibilityLabel("Zoom Out")
            Button { withAnimation(.snappy) { setScale(scale * 1.5, anchor: nil, in: size) } } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(scale >= Self.maxScale)
                .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.glass)
        .padding(16)
    }

    /// Double-tap zooms in around the tapped point, or back out to fit.
    private func toggleZoom(at location: CGPoint, in size: CGSize) {
        guard scale == 1 else { return reset() }
        setScale(Self.doubleTapScale, anchor: CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2), in: size)
    }

    /// Sets the scale within 1×–5×, keeping `anchor` (relative to the center) where it is, and
    /// keeps the content covering the view.
    private func setScale(_ value: CGFloat, anchor: CGPoint?, in size: CGSize?) {
        let target = min(max(value, 1), Self.maxScale)
        if target == 1 { return reset() }
        let anchor = anchor ?? .zero
        let ratio = target / scale
        var next = CGSize(width: anchor.x - (anchor.x - offset.width) * ratio, height: anchor.y - (anchor.y - offset.height) * ratio)
        if let size { next = clamped(next, scale: target, in: size) }
        scale = target
        offset = next
        zoomed = true
    }

    private func clamped(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2, maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    private func reset() {
        scale = 1
        offset = .zero
        zoomed = false
    }
    #endif
}

#if os(iOS)
/// Lets VoiceOver's zoom action reach the scroll view.
@MainActor
private final class ZoomController {
    weak var scrollView: UIScrollView?

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        scrollView.setZoomScale(scrollView.zoomScale * factor, animated: true)
    }
}

/// UIKit's zooming scroll view, as in Photos: the pinch stays under the fingers, pans keep their
/// momentum, and the content bounces back inside its edges.
private struct ZoomScrollView<Content: View>: UIViewRepresentable {
    @Binding var zoomed: Bool
    let controller: ZoomController
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(host: UIHostingController(rootView: content)) }

    func makeUIView(context: Context) -> FittingScrollView {
        let scrollView = FittingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = ZoomableContent<Content>.maxScale
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear

        let host = context.coordinator.host
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        scrollView.zoomView = host.view
        scrollView.addSubview(host.view)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        controller.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: FittingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.host.rootView = content
        coordinator.zoomed = $zoomed
        // Zoomed out from outside, e.g. by paging to another photo.
        if !zoomed, coordinator.reported, scrollView.zoomScale > 1 {
            coordinator.reported = false
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                scrollView.zoomScale = 1
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>
        var zoomed: Binding<Bool>?
        /// The zoom state last reported to SwiftUI.
        var reported = false

        init(host: UIHostingController<Content>) { self.host = host }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            report(scrollView.zoomScale > 1.01)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            report(scale > 1.01)
        }

        private func report(_ isZoomed: Bool) {
            guard isZoomed != reported else { return }
            reported = isZoomed
            zoomed?.wrappedValue = isZoomed
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let point = gesture.location(in: host.view)
            let scale = ZoomableContent<Content>.doubleTapScale
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// Sizes the zoomed view to fill the scroll view at 1×, and refits it when the size changes
/// (rotation, a resized window).
private final class FittingScrollView: UIScrollView {
    weak var zoomView: UIView?
    private var fittedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let zoomView, bounds.size != fittedSize, bounds.width > 0, bounds.height > 0 else { return }
        fittedSize = bounds.size
        zoomScale = 1
        zoomView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
}
#endif
