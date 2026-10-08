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
    @State private var page: Int?
    @State private var zoomed = false
    @Environment(\.dismiss) private var dismiss

    init(photos: [TripPhoto], start: Int) {
        self.photos = photos
        _page = State(initialValue: start)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos.indices, id: \.self) { index in
                    ZoomablePhoto(photo: photos[index], zoomed: page == index ? $zoomed : .constant(false))
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .scrollDisabled(zoomed)
        .background(.black)
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay(alignment: .bottom) { caption }
        .onChange(of: page) { zoomed = false }
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.impact(weight: .light), trigger: zoomed)
        .preferredColorScheme(.dark)
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

/// One photo fitted to the screen, zoomable from 1× to 5×.
private struct ZoomablePhoto: View {
    let photo: TripPhoto
    @Binding var zoomed: Bool
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            image
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale * pinch)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .contentShape(Rectangle())
                .gesture(magnify)
                .gesture(pan, including: scale > 1 ? .all : .subviews)
                .onTapGesture(count: 2) { location in
                    withAnimation(.snappy) { toggleZoom(at: location, in: proxy.size) }
                }
                #if os(macOS)
                .overlay(alignment: .bottomTrailing) { zoomButtons }
                #endif
        }
        .clipped()
        .onChange(of: zoomed) { _, isZoomed in
            if !isZoomed, scale != 1 { withAnimation(.snappy) { reset() } }
        }
        .accessibilityLabel(photo.caption ?? String(localized: "Photo"))
        .accessibilityZoomAction { action in
            withAnimation(.snappy) { setScale(action.direction == .zoomIn ? scale * 2 : scale / 2) }
        }
    }

    private var image: some View {
        // Fitted, not cropped, so the whole photo shows before zooming in.
        SummaryRemoteImage(url: photo.imageURL) {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
        }
        .scaledToFit()
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                withAnimation(.snappy) { setScale(scale * value.magnification) }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    #if os(macOS)
    /// Mice can't pinch, so the Mac gets buttons too.
    private var zoomButtons: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.snappy) { setScale(scale / 1.5) } } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale <= 1)
                .accessibilityLabel("Zoom Out")
            Button { withAnimation(.snappy) { setScale(scale * 1.5) } } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(scale >= Self.maxScale)
                .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.glass)
        .padding(16)
    }
    #endif

    /// Double-tap zooms in to 2.5× around the tapped point, or back out to fit.
    private func toggleZoom(at location: CGPoint, in size: CGSize) {
        guard scale == 1 else { return reset() }
        let target: CGFloat = 2.5
        scale = target
        offset = CGSize(
            width: (size.width / 2 - location.x) * (target - 1),
            height: (size.height / 2 - location.y) * (target - 1)
        )
        zoomed = true
    }

    private func setScale(_ value: CGFloat) {
        let clamped = min(max(value, 1), Self.maxScale)
        if clamped == 1 { return reset() }
        // Keep the zoomed photo's center where it was relative to the new scale.
        offset = CGSize(width: offset.width * clamped / scale, height: offset.height * clamped / scale)
        scale = clamped
        zoomed = true
    }

    private func reset() {
        scale = 1
        offset = .zero
        zoomed = false
    }
}
