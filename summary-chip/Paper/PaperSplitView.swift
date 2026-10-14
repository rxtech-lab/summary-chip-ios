import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A draggable split that keeps the editor and PDF alive while their widths change. While the
/// divider is dragged only a guide follows the finger; the panes take their new widths once, on
/// release, so the editor and preview don't relayout on every frame of the drag.
struct PaperSplitView<Editor: View, Preview: View>: View {
    @AppStorage("paperEditorWidthFraction") private var editorFraction = 0.5
    @GestureState private var dragTranslation: CGFloat?
    @State private var isHovering = false
    @State private var adjustments = 0
    @Environment(\.layoutDirection) private var layoutDirection
    private let showsEditor: Bool
    private let editor: Editor
    private let preview: Preview

    /// With `showsEditor` off the preview takes the whole width; it stays the same view, so the
    /// PDF and reader keep their place.
    init(showsEditor: Bool = true, @ViewBuilder editor: () -> Editor, @ViewBuilder preview: () -> Preview) {
        self.showsEditor = showsEditor
        self.editor = editor()
        self.preview = preview()
    }

    private var dividerWidth: CGFloat {
        #if os(iOS)
        44
        #else
        12
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - (showsEditor ? dividerWidth : 0))
            let editorWidth = showsEditor ? width(in: availableWidth) : 0
            HStack(spacing: 0) {
                if showsEditor {
                    editor
                        .frame(width: editorWidth, height: geometry.size.height)
                        .clipped()
                        .transition(.move(edge: .leading))
                    divider(availableWidth: availableWidth, editorWidth: editorWidth)
                }
                preview
                    .frame(width: availableWidth - editorWidth, height: geometry.size.height)
                    .clipped()
            }
            .overlay(alignment: .leading) {
                if let dragTranslation {
                    resizeGuide
                        .padding(.leading, width(in: availableWidth, translation: dragTranslation))
                }
            }
        }
        .sensoryFeedback(.selection, trigger: dragTranslation != nil) { _, dragging in dragging }
        .sensoryFeedback(.selection, trigger: adjustments)
    }

    /// Where the divider lands when the drag ends.
    private var resizeGuide: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 6, height: 40)
        }
        .frame(width: dividerWidth)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func divider(availableWidth: CGFloat, editorWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 1)
            Capsule()
                .fill(isHovering || dragTranslation != nil ? Color.accentColor : Color.secondary)
                .frame(width: 4, height: 32)
        }
        .frame(width: dividerWidth)
        .frame(maxHeight: .infinity)
        // Kept out of the safe area so the divider stops at the nav bar, which then spans the
        // editor and preview as one bar.
        .background(.bar, ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .gesture(resizeGesture(availableWidth: availableWidth))
        .onHover { hover($0) }
        .onDisappear { hover(false) }
        .help("Drag to resize the editor and preview.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize Editor and Preview")
        .accessibilityValue(Text("Editor \(percentage(editorWidth, of: availableWidth)) percent, preview \(100 - percentage(editorWidth, of: availableWidth)) percent"))
        .accessibilityHint("Swipe up or down to adjust the editor width.")
        .accessibilityAdjustableAction { direction in
            guard availableWidth > 0 else { return }
            switch direction {
            case .increment: adjust(by: availableWidth * 0.05, availableWidth: availableWidth)
            case .decrement: adjust(by: -availableWidth * 0.05, availableWidth: availableWidth)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("paper-resize-divider")
    }

    private func resizeGesture(availableWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragTranslation) { value, translation, _ in
                translation = layoutDirection == .leftToRight ? value.translation.width : -value.translation.width
            }
            .onEnded { value in
                let translation = layoutDirection == .leftToRight ? value.translation.width : -value.translation.width
                adjust(by: translation, availableWidth: availableWidth)
            }
    }

    /// Adapt the minimum to narrow windows or an open sidebar without overflowing the page.
    private func width(in availableWidth: CGFloat, translation: CGFloat = 0) -> CGFloat {
        let minimum = min(280, availableWidth * 0.35)
        let fraction = editorFraction.isFinite ? editorFraction : 0.5
        let initial = min(max(availableWidth * fraction, minimum), availableWidth - minimum)
        return min(max(initial + translation, minimum), availableWidth - minimum)
    }

    private func adjust(by translation: CGFloat, availableWidth: CGFloat) {
        guard availableWidth > 0 else { return }
        let fraction = Double(width(in: availableWidth, translation: translation) / availableWidth)
        guard fraction != editorFraction else { return }
        editorFraction = fraction
        adjustments += 1
    }

    private func percentage(_ width: CGFloat, of availableWidth: CGFloat) -> Int {
        availableWidth > 0 ? Int((width / availableWidth * 100).rounded()) : 50
    }

    private func hover(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        #if os(macOS)
        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        #endif
    }
}
