#if os(iOS) || os(macOS)
import SwiftUI

/// "Not what you expected?" after generating: deletes the new summary. In the app a link
/// summary can also be reopened in Safari, so the user can share the page itself to Chippy (the
/// share extension sends the page text exactly as Safari shows it). Extensions only discard.
public struct DiscardSummarySheet: View {
    let api: SummaryAPIClient
    let summary: Summary
    /// Offer "Discard & Open in Safari" for link summaries. False in extensions.
    let offersSafari: Bool
    let onDiscarded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isDiscarding = false
    @State private var errorMessage: String?
    @State private var discardCount = 0

    public init(api: SummaryAPIClient, summary: Summary, offersSafari: Bool, onDiscarded: @escaping () -> Void) {
        self.api = api
        self.summary = summary
        self.offersSafari = offersSafari
        self.onDiscarded = onDiscarded
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.title).font(.headline)
                        Text(explanation).foregroundStyle(.secondary)
                    }
                    if let safariURL {
                        ShareExtensionDiagram(host: safariURL.host()?.replacingOccurrences(of: "www.", with: "") ?? safariURL.absoluteString)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    actions
                }
                .padding(24)
            }
            .navigationTitle(Text("Discard Summary", bundle: .module))
            .summaryInlineNavigationTitle()
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module), role: .cancel) { dismiss() }.disabled(isDiscarding)
                }
            }
            #endif
        }
        .summarySheetSize()
        .disabled(isDiscarding)
        .interactiveDismissDisabled(isDiscarding)
        .overlay {
            if isDiscarding { ActionStatusOverlay(String(localized: "Discarding…", bundle: .module), isWorking: true) }
        }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: discardCount)
    }

    /// The page to reopen: only link summaries, only in the app.
    private var safariURL: URL? {
        guard offersSafari, let url = summary.sourceUrl, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    private var explanation: String {
        safariURL == nil
            ? String(localized: "The summary and its share link are deleted permanently.", bundle: .module)
            : String(localized: "The summary and its share link are deleted permanently. To try again from the page itself, open it in Safari and share it to Chippy.", bundle: .module)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let safariURL {
                Button(role: .destructive) {
                    Task { await discard(thenOpen: safariURL) }
                } label: {
                    Label(String(localized: "Discard & Open in Safari", bundle: .module), systemImage: "safari")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("discard-open-safari")
            }
            Button(role: .destructive) {
                Task { await discard(thenOpen: nil) }
            } label: {
                Label(String(localized: "Discard", bundle: .module), systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .fontWeight(safariURL == nil ? .semibold : .regular)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .accessibilityIdentifier("discard-summary")
            #if os(macOS)
            // Sheet navigation stacks don't display toolbar placements on macOS.
            Button(role: .cancel) { dismiss() } label: {
                Text("Keep Summary", bundle: .module).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            #endif
        }
    }

    private func discard(thenOpen url: URL?) async {
        guard !isDiscarding else { return }
        errorMessage = nil
        isDiscarding = true
        defer { isDiscarding = false }
        do {
            try await api.deleteSummary(id: summary.id)
        } catch let error as SummaryAPIError where error.isNotFound {
            // Already gone; nothing left to discard.
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        discardCount += 1
        dismiss()
        if let url { SafariOpener.open(url, fallback: openURL) }
        onDiscarded()
    }
}
#endif
