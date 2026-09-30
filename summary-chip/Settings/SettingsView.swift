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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    profile
                }

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
            .navigationTitle("Settings")
            .navigationDestination(for: LegalDocument.self) { document in
                LegalDocumentView(document: document, baseURL: environment.configuration.apiBaseURL)
            }
            .sheet(isPresented: $showsDeleteAccount) {
                DeleteAccountSheet(environment: environment, state: $deletion)
            }
            .confirmationDialog("Sign out of Summary Chip?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
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

    private var user: User? { environment.authManager.currentUser }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
}

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
