import RxAuthSwift
import SummaryKit
import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @State private var confirmsSignOut = false
    @State private var showsDeleteAccount = false
    @State private var deletion: AccountDeletionState = .none
    @State private var cacheSize: Int?
    @State private var confirmsClearCache = false
    @State private var clearedCount = 0
    @State private var helpSheet: HelpSheet?
    @State private var showsCredits = false
    @Environment(\.chatPanelVisibility) private var chatPanelVisibility

    var body: some View {
        NavigationStack {
            settingsContent
            .navigationTitle("Settings")
            .summarySearchToolbar()
            .toolbar { ChatPanelToolbarContent(isVisible: chatPanelVisibility) }
            .navigationDestination(for: LegalDocument.self) { document in
                LegalDocumentView(document: document, baseURL: environment.configuration.apiBaseURL)
            }
            .sheet(isPresented: $showsDeleteAccount) {
                DeleteAccountSheet(environment: environment, state: $deletion)
            }
            .sheet(isPresented: $showsCredits) { SummaryCreditsSheet(environment: environment) }
            .sheet(item: $helpSheet) { sheet in
                switch sheet {
                case .welcome:
                    EducationSheet(pages: EducationPage.welcome, allowsDismissal: true) { helpSheet = nil }
                case .features:
                    EducationSheet(pages: EducationPage.features, allowsDismissal: true) { helpSheet = nil }
                }
            }
            .confirmationDialog("Sign out of Chippy?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await environment.signOut() }
                }
            }
            .confirmationDialog(
                "Clear \((cacheSize ?? 0).formatted(.byteCount(style: .file))) of cached data?",
                isPresented: $confirmsClearCache,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    environment.clearCache()
                    clearedCount += 1
                    Task { cacheSize = await environment.cacheSize() }
                }
            } message: {
                Text("Saved summaries and images are removed from this device. Your summaries stay in your account.")
            }
            .sensoryFeedback(.success, trigger: clearedCount)
            .task {
                cacheSize = await environment.cacheSize()
            }
            .task {
                // A failed read shows "nothing pending"; requesting again is idempotent and corrects it.
                deletion = (try? await environment.api.accountDeletionState()) ?? .none
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        #if os(macOS)
        macForm
        #else
        iOSList
        #endif
    }

    #if os(macOS)
    private var macForm: some View {
        Form {
            Section {
                profile
            }

            Section("Help") {
                SettingsActionRow("Welcome Tour", systemImage: "hand.wave.fill", tint: .orange,
                                  detail: "A quick look at how Chippy works.") {
                    Button("Show") { helpSheet = .welcome }
                        .accessibilityIdentifier("settings-welcome")
                }
                SettingsActionRow("What’s New", systemImage: "sparkles", tint: .purple,
                                  detail: "Features added in recent updates.") {
                    Button("Show") { helpSheet = .features }
                        .accessibilityIdentifier("settings-features")
                }
            }

            creditsSection

            Section("Legal") {
                ForEach(LegalDocument.allCases, id: \.self) { document in
                    NavigationLink(value: document) {
                        SettingsRowLabel(document.title, systemImage: document.systemImage, tint: .gray)
                    }
                    .accessibilityIdentifier("\(document.rawValue)-link")
                }
            }

            Section {
                SettingsActionRow("Offline Cache", systemImage: "internaldrive.fill", tint: .blue,
                                  detail: cacheSize.map { "\($0.formatted(.byteCount(style: .file))) used" } ?? "Calculating…") {
                    Button("Clear Cache…") {
                        Task {
                            cacheSize = await environment.cacheSize()
                            confirmsClearCache = true
                        }
                    }
                    .disabled(cacheSize == 0)
                    .accessibilityIdentifier("clear-cache-button")
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Summaries and images saved for offline reading. They download again when you open them online.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                    .accessibilityIdentifier("app-version")
                LabeledContent("Build", value: Self.build)
                    .accessibilityIdentifier("app-build")
            }

            Section("Account") {
                SettingsActionRow("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", tint: .gray,
                                  detail: "Also signs out the share extension.") {
                    Button("Sign Out…") { confirmsSignOut = true }
                        .accessibilityIdentifier("sign-out-button")
                }
                SettingsActionRow(
                    deletion.pendingDeletion ? "Account Scheduled for Deletion" : "Delete Account",
                    systemImage: "trash.fill",
                    tint: .red,
                    detail: deletion.deletionScheduledAt.map {
                        "Deletes \($0.formatted(date: .abbreviated, time: .shortened))."
                    } ?? "Permanently removes your account and summaries."
                ) {
                    Button(deletion.pendingDeletion ? "Manage…" : "Delete…", role: .destructive) {
                        showsDeleteAccount = true
                    }
                    .accessibilityIdentifier("delete-account-button")
                }
            }
        }
        .formStyle(.grouped)
        .buttonStyle(PlainTextButtonStyle())
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .background(Color.summaryGroupedBackground)
    }
    #else
    private var iOSList: some View {
        List {
            Section {
                profile
            }

            Section("Discover") {
                Button { helpSheet = .welcome } label: {
                    Label("Welcome Tour", systemImage: "hand.wave")
                }
                .accessibilityIdentifier("settings-welcome")
                Button { helpSheet = .features } label: {
                    Label("What’s New", systemImage: "sparkles")
                }
                .accessibilityIdentifier("settings-features")
            }

            creditsSection

            Section("Legal") {
                ForEach(LegalDocument.allCases, id: \.self) { document in
                    NavigationLink(value: document) {
                        Label(document.title, systemImage: document.systemImage)
                    }
                    .accessibilityIdentifier("\(document.rawValue)-link")
                }
            }

            Section {
                Button {
                    Task {
                        cacheSize = await environment.cacheSize()
                        confirmsClearCache = true
                    }
                } label: {
                    LabeledContent {
                        if let cacheSize {
                            Text(cacheSize.formatted(.byteCount(style: .file)))
                        }
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                }
                .accessibilityIdentifier("clear-cache-button")
            } header: {
                Text("Storage")
            } footer: {
                Text("Summaries and images saved for offline reading. They download again when you open them online.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                    .accessibilityIdentifier("app-version")
                LabeledContent("Build", value: Self.build)
                    .accessibilityIdentifier("app-build")
            }

            Section {
                Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sign-out-button")
            } footer: {
                Text("Signing out also signs out the share extension and the iMessage app.")
            }

            Section {
                Button(role: .destructive) {
                    showsDeleteAccount = true
                } label: {
                    VStack(spacing: 2) {
                        Text(deletion.pendingDeletion ? "Account Scheduled for Deletion" : "Delete My Account")
                        if let date = deletion.deletionScheduledAt {
                            Text("Deletes \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("delete-account-button")
            }
        }
    }
    #endif

    private var profile: some View {
        HStack(spacing: 14) {
            AccountAvatar(name: user?.name ?? user?.email ?? "", url: user?.image.flatMap(URL.init(string:)))
            VStack(alignment: .leading, spacing: 2) {
                Text(user?.name ?? "Signed in")
                    .font(.headline)
                if let email = user?.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("signed-in-profile")
    }

    private var creditsSection: some View {
        Section("Usage") {
            Button { showsCredits = true } label: {
                Label("Summaries & Points", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("summary-credits")
        }
    }

    private var user: User? { environment.authManager.currentUser }

    private enum HelpSheet: String, Identifiable {
        case welcome, features
        var id: String { rawValue }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
}

#if os(macOS)
/// System Settings–style row: tinted icon tile, title, secondary detail, and a trailing action.
private struct SettingsActionRow<Action: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let detail: String?
    @ViewBuilder let action: () -> Action

    init(
        _ title: String,
        systemImage: String,
        tint: Color,
        detail: String? = nil,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title, systemImage: systemImage, tint: tint, detail: detail)
            Spacer(minLength: 16)
            action()
        }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let tint: Color
    var detail: String?

    init(_ title: String, systemImage: String, tint: Color, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Borderless text action in the accent color, red for destructive roles.
private struct PlainTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
            .contentShape(.rect)
            .pointerStyle(.link)
    }
}
#endif

/// Profile photo from the identity provider, over initials while it loads or when there is none.
struct AccountAvatar: View {
    let name: String
    let url: URL?
    var size: CGFloat = 56

    private var initials: String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(.tint.opacity(0.15))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.tint)
            if let url {
                SummaryRemoteImage(url: url) { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
