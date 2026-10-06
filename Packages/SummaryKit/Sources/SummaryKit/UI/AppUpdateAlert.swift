#if os(iOS) || os(macOS)
import SwiftUI

extension View {
    /// Shows a native alert whenever the server answers `426 APP_UPDATE_REQUIRED`, asking the user to
    /// update to the version the feature needs. `onUpdate` replaces opening the server's `updateUrl`
    /// (the Mac app checks for updates with Sparkle instead).
    public func appUpdateAlert(onUpdate: (() -> Void)? = nil) -> some View {
        modifier(AppUpdateAlertModifier(onUpdate: onUpdate))
    }
}

private struct AppUpdateAlertModifier: ViewModifier {
    let onUpdate: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var center = AppUpdateCenter.shared

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Update Chippy", bundle: .module, comment: "Alert title: the app is too old for a feature"),
                isPresented: Binding(get: { center.requirement != nil }, set: { if !$0 { center.requirement = nil } }),
                presenting: center.requirement
            ) { requirement in
                if onUpdate != nil || requirement.updateURL != nil {
                    Button(String(localized: "Update", bundle: .module, comment: "Alert button: update the app")) {
                        if let onUpdate {
                            onUpdate()
                        } else if let url = requirement.updateURL {
                            openURL(url)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button(String(localized: "Not Now", bundle: .module, comment: "Alert button: dismiss the update request"), role: .cancel) {}
            } message: { requirement in
                Text(message(for: requirement))
            }
            .sensoryFeedback(.warning, trigger: center.requirement) { _, new in new != nil }
    }

    private func message(for requirement: AppUpdateRequirement) -> String {
        let current = AppVersion.current ?? "?"
        guard !requirement.requiredVersion.isEmpty else {
            return String(localized: "This feature needs a newer version of Chippy. You're using \(current).", bundle: .module)
        }
        return String(localized: "This feature needs Chippy \(requirement.requiredVersion) or later. You're using \(current). Update the app to keep using it.", bundle: .module)
    }
}
#endif
