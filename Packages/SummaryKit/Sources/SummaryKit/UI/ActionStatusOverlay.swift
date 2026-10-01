#if os(iOS) || os(macOS)
import SwiftUI

/// Progress overlay for in-flight actions. Outcomes that need acknowledging use `statusAlert`.
public struct ActionStatusOverlay: View {
    let message: String
    let isWorking: Bool

    public init(_ message: String, isWorking: Bool = true) {
        self.message = message
        self.isWorking = isWorking
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 16) {
                if isWorking { ProgressView() }
                Text(message).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .accessibilityIdentifier("action-status-overlay")
    }
}

public extension View {
    /// Native alert shown while `message` is non-nil; `onDismiss` runs when it's closed.
    func statusAlert(_ title: LocalizedStringKey, message: String?, onDismiss: @escaping () -> Void) -> some View {
        alert(
            title,
            isPresented: Binding(get: { message != nil }, set: { if !$0 { onDismiss() } }),
            presenting: message
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}
#endif
