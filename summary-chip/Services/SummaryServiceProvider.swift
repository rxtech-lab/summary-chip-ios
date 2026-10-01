#if os(macOS)
import AppKit

/// "Summarize with Summary Chip" in the system Services menu (right-click › Services in any app).
/// Takes the selected text or link and opens the New Summary sheet with it filled in.
/// The menu item itself is declared under `NSServices` in the macOS Info.plist.
@MainActor
final class SummaryServiceProvider: NSObject {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func register() {
        NSApplication.shared.servicesProvider = self
        // Picks up Info.plist changes without a logout, e.g. right after an update.
        NSUpdateDynamicServices()
    }

    /// Selector matches `NSMessage` (`summarize`) in Info.plist.
    @objc func summarize(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.content(of: pasteboard) else {
            error.pointee = "Select some text or a link to summarize." as NSString
            return
        }
        NSApplication.shared.activate()
        environment.pendingServiceText = text
    }

    private static func content(of pasteboard: NSPasteboard) -> String? {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, !url.isFileURL {
            return url.absoluteString
        }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
#endif
