#if os(macOS)
import AppKit
import Observation
import Sparkle
import SwiftUI

/// Sparkle owns scheduling, verification, installation and its built-in update windows.
@MainActor @Observable
final class UpdateService: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateService()

    var automaticallyChecks = true
    var automaticallyDownloads = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var sheet: NSWindow?
    @ObservationIgnored private var started = false

    private var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() {
        guard !started else { return }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if (!arguments.contains(where: { $0.hasPrefix("--test-update-feed=") }) &&
            (arguments.contains("--preview-mac") || arguments.contains("--preview-education")))
            || arguments.contains("--disable-updates")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        #endif
        started = true
        // Sparkle shows its own alert if the updater fails to start.
        controller.startUpdater()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let argument = arguments.first(where: { $0.hasPrefix("--test-update-feed=") }),
           let url = URL(string: String(argument.dropFirst("--test-update-feed=".count))),
           url.host == "127.0.0.1", url.scheme == "http" {
            return url.absoluteString
        }
        #endif
        return nil
    }

    func checkForUpdates() {
        start()
        guard started else { return }
        closeSheet()
        controller.checkForUpdates(nil)
    }

    func showSettings() {
        guard sheet == nil else { sheet?.makeKeyAndOrderFront(nil); return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        let window = NSWindow(contentViewController: NSHostingController(rootView: SoftwareUpdateSettingsSheet(service: self)))
        window.styleMask = [.titled]
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        sheet = window
        // Sheet windows may be key themselves; attach to the containing app window.
        let keyWindow = NSApp.keyWindow
        if let parent = keyWindow?.sheetParent ?? keyWindow ?? NSApp.mainWindow {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func saveSettings() {
        updater.automaticallyChecksForUpdates = automaticallyChecks
        updater.automaticallyDownloadsUpdates = automaticallyChecks && automaticallyDownloads
    }

    func closeSheet() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        self.sheet = nil
    }
}

private struct SoftwareUpdateSettingsSheet: View {
    @Bindable var service: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Software Update", systemImage: "arrow.triangle.2.circlepath")
                .font(.title2.bold())
            Text("Keep Chippy up to date.").foregroundStyle(.secondary)
            Toggle("Automatically check for updates", isOn: $service.automaticallyChecks)
                .onChange(of: service.automaticallyChecks) { service.saveSettings() }
            Toggle("Automatically download and install updates", isOn: $service.automaticallyDownloads)
                .disabled(!service.automaticallyChecks)
                .onChange(of: service.automaticallyDownloads) { service.saveSettings() }
            Spacer(minLength: 16)
            HStack {
                Button("Close", action: service.closeSheet)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check for Updates…", action: service.checkForUpdates)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460, height: 290)
    }
}
#endif
