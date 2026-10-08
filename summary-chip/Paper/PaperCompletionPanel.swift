#if os(macOS)
import AppKit
import Observation
import SummaryKit
import SwiftUI

/// The Mac editor's completion list: a borderless panel under the caret listing each completion
/// with its description, and the selected one's description in full below. The text view keeps
/// the keyboard: it moves the selection and picks (see `PaperTextView.doCommand(by:)`).
final class PaperCompletionPanel: NSPanel {
    @Observable
    final class Model {
        var suggestions: [LaTeXSuggestion] = []
        var selection = 0

        var selected: LaTeXSuggestion? { suggestions.indices.contains(selection) ? suggestions[selection] : nil }
    }

    static let rowHeight: CGFloat = 24
    static let width: CGFloat = 460

    let model = Model()
    var onPick: ((LaTeXSuggestion) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        let list = PaperCompletionList(model: model) { [weak self] suggestion in self?.onPick?(suggestion) }
        contentView = NSHostingView(rootView: list)
    }

    var isShown: Bool { parent != nil }

    /// Shows `suggestions` under `caret` (screen coordinates), above it when there's no room below.
    func show(_ suggestions: [LaTeXSuggestion], below caret: NSRect, in window: NSWindow) {
        if suggestions.map(\.label) != model.suggestions.map(\.label) { model.selection = 0 }
        model.suggestions = suggestions
        let rows = CGFloat(min(suggestions.count, 8))
        let height = rows * Self.rowHeight + 8 + (suggestions.contains { $0.detail != nil } ? 56 : 0)
        var frame = NSRect(x: caret.minX - 8, y: caret.minY - 4 - height, width: Self.width, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = caret.maxY + 4 }
            frame.origin.x = min(max(screen.minX, frame.minX), screen.maxX - frame.width)
        }
        setFrame(frame, display: true)
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        guard isShown else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !model.suggestions.isEmpty else { return }
        model.selection = (model.selection + delta + model.suggestions.count) % model.suggestions.count
    }
}

private struct PaperCompletionList: View {
    let model: PaperCompletionPanel.Model
    let onPick: (LaTeXSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            row(suggestion, isSelected: index == model.selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(suggestion) }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.selection) { _, selection in proxy.scrollTo(selection) }
            }
            if model.suggestions.contains(where: { $0.detail != nil }) {
                Divider()
                Text(model.selected?.detail ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .frame(height: 55)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func row(_ suggestion: LaTeXSuggestion, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(suggestion.label)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let detail = suggestion.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: PaperCompletionPanel.rowHeight)
        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
    }
}
#endif
