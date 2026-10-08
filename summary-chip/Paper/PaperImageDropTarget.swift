import SwiftUI

/// A temporary drop hint over the editor or image preview, without adding permanent controls.
struct PaperImageDropTarget: ViewModifier {
    let isEnabled: Bool
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrop(of: PaperImageImport.dropTypes, isTargeted: $isTargeted, perform: onDrop)
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.tint.opacity(0.08))
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                            .overlay {
                                Label("Drop to Add Image", systemImage: "photo.badge.plus")
                                    .font(.headline)
                                    .padding()
                                    .glassEffect(.regular, in: Capsule())
                            }
                            .padding(4)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("paper-image-drop-hint")
                    }
                }
                .sensoryFeedback(.selection, trigger: isTargeted) { _, targeted in targeted }
        } else {
            content
        }
    }
}
