#if os(macOS)
import AppKit
import Observation
import Sparkle
import SwiftUI

/// Sparkle owns scheduling, verification and installation; this driver presents native sheets.
@MainActor @Observable
final class UpdateService: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    static let shared = UpdateService()

    var title = "Software Update"
    var message = ""
    var isBusy = false
    var progress: Double?
    var primaryTitle: String?
    var secondaryTitle = "Close"
    var showsSettings = false
    var releaseURL: URL?
    var automaticallyChecks = true
    var automaticallyDownloads = false

    @ObservationIgnored private var updater: SPUUpdater!
    @ObservationIgnored private var sheet: NSWindow?
    @ObservationIgnored private var primaryAction: (() -> Void)?
    @ObservationIgnored private var secondaryAction: (() -> Void)?
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startupError: String?

    private override init() {
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
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
        do {
            try updater.start()
            started = true
        } catch {
            startupError = error.localizedDescription
        }
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
        if sheet != nil && !showsSettings {
            sheet?.makeKeyAndOrderFront(nil)
            return
        }
        if let startupError {
            present(title: "Updates Unavailable", message: startupError)
        } else if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }
    }

    func showSettings() {
        guard sheet == nil else { sheet?.makeKeyAndOrderFront(nil); return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        present(title: "Software Update", message: "Keep Chippy up to date.",
                primaryTitle: "Check for Updates…", primary: { [weak self] in self?.checkForUpdates() })
        showsSettings = true
    }

    func saveSettings() {
        updater.automaticallyChecksForUpdates = automaticallyChecks
        updater.automaticallyDownloadsUpdates = automaticallyChecks && automaticallyDownloads
    }

    func performPrimaryAction() {
        let action = primaryAction
        primaryAction = nil
        action?()
    }

    func performSecondaryAction() {
        let action = secondaryAction
        secondaryAction = nil
        closeSheet()
        action?()
    }

    private func present(title: String, message: String, busy: Bool = false,
                         primaryTitle: String? = nil, primary: (() -> Void)? = nil,
                         secondaryTitle: String = "Close", secondary: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        isBusy = busy
        progress = nil
        showsSettings = false
        releaseURL = nil
        self.primaryTitle = primaryTitle
        primaryAction = primary
        self.secondaryTitle = secondaryTitle
        secondaryAction = secondary
        guard sheet == nil else { return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SoftwareUpdateSheet(service: self)))
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

    private func closeSheet() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        self.sheet = nil
        primaryAction = nil
        secondaryAction = nil
    }

    func show(_ request: SPUUpdatePermissionRequest,
                                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        present(title: "Automatic Updates", message: "Check for new Chippy versions automatically?",
                primaryTitle: "Enable", primary: { [weak self] in
                    self?.closeSheet()
                    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
                }, secondaryTitle: "Not Now", secondary: {
                    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
                })
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        present(title: "Software Update", message: "Checking for updates…", busy: true,
                secondaryTitle: "Cancel", secondary: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let informationOnly = appcastItem.isInformationOnlyUpdate
        present(title: "Update Available",
                message: "Chippy \(appcastItem.displayVersionString) is available.",
                primaryTitle: informationOnly ? "View Update" : (state.stage == .installing ? "Install and Relaunch" : "Install Update"),
                primary: { [weak self] in
                    if informationOnly {
                        if let url = appcastItem.infoURL { NSWorkspace.shared.open(url) }
                        self?.closeSheet()
                        reply(.dismiss)
                    } else {
                        reply(.install)
                    }
                }, secondaryTitle: "Later", secondary: { reply(.dismiss) })
        releaseURL = appcastItem.releaseNotesURL ?? appcastItem.infoURL
    }

    // Release details are available from the GitHub release linked by the feed.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        present(title: "Software Update", message: error.localizedDescription, secondary: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        present(title: "Update Failed", message: error.localizedDescription, secondary: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        present(title: "Software Update", message: "Downloading update…", busy: true,
                secondaryTitle: "Cancel", secondary: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        if expectedBytes > 0 { progress = min(Double(receivedBytes) / Double(expectedBytes), 1) }
    }

    func showDownloadDidStartExtractingUpdate() {
        present(title: "Software Update", message: "Preparing update…", busy: true, secondaryTitle: "")
    }

    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        present(title: "Ready to Install", message: "Restart Chippy to finish updating.",
                primaryTitle: "Install and Relaunch", primary: { reply(.install) },
                secondaryTitle: "Later", secondary: { reply(.dismiss) })
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        present(title: "Software Update", message: "Installing update…", busy: true,
                primaryTitle: applicationTerminated ? nil : "Retry Restart",
                primary: applicationTerminated ? nil : retryTerminatingApplication, secondaryTitle: "")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        present(title: "Update Installed", message: "Chippy is up to date.", secondary: acknowledgement)
    }

    func dismissUpdateInstallation() { closeSheet() }
    func showUpdateInFocus() { sheet?.makeKeyAndOrderFront(nil) }
}

private struct SoftwareUpdateSheet: View {
    @Bindable var service: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(service.title, systemImage: "arrow.triangle.2.circlepath")
                .font(.title2.bold())
            Text(service.message).foregroundStyle(.secondary)
                .opacity(service.isBusy ? 0 : 1)
            if let url = service.releaseURL {
                Link(destination: url) { Label("Release Notes", systemImage: "doc.text") }
            }
            if service.showsSettings {
                Toggle("Automatically check for updates", isOn: $service.automaticallyChecks)
                    .onChange(of: service.automaticallyChecks) { service.saveSettings() }
                Toggle("Automatically download and install updates", isOn: $service.automaticallyDownloads)
                    .disabled(!service.automaticallyChecks)
                    .onChange(of: service.automaticallyDownloads) { service.saveSettings() }
            }
            Spacer(minLength: 16)
            HStack {
                if !service.secondaryTitle.isEmpty {
                    Button(service.secondaryTitle, action: service.performSecondaryAction)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if let title = service.primaryTitle {
                    Button(title, action: service.performPrimaryAction)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 460, height: service.showsSettings ? 290 : 240)
        .overlay {
            if service.isBusy {
                VStack(spacing: 12) {
                    if let progress = service.progress {
                        ProgressView(value: progress).frame(width: 220)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text(service.message).font(.callout)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)
                .accessibilityIdentifier("software-update-progress")
            }
        }
    }
}
#endif
