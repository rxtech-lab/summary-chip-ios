#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// Progress overlay for in-flight actions. Outcomes that need acknowledging use `statusAlert`.
public struct ActionStatusOverlay: View {
    let message: String
    let isWorking: Bool
    let progress: Double?
    let cancelTitle: LocalizedStringKey
    let onCancel: (() -> Void)?

    /// Pass `progress` (0...1) for a determinate bar, and `onCancel` to offer a way out inside the overlay.
    public init(
        _ message: String,
        isWorking: Bool = true,
        progress: Double? = nil,
        cancelTitle: LocalizedStringKey = "Cancel",
        onCancel: (() -> Void)? = nil
    ) {
        self.message = message
        self.isWorking = isWorking
        self.progress = progress
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 16) {
                if progress == nil, isWorking { ProgressView() }
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1)).progressViewStyle(.linear)
                }
                if let onCancel {
                    Button(cancelTitle, action: onCancel).keyboardShortcut(.cancelAction)
                }
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
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    /// Package-internal variant whose title is already resolved (e.g. `Text("…", bundle: .module)`).
    internal func statusAlert(_ title: Text, message: String?, onDismiss: @escaping () -> Void) -> some View {
        alert(
            title,
            isPresented: Binding(get: { message != nil }, set: { if !$0 { onDismiss() } }),
            presenting: message
        ) { _ in
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}
#endif
