import RxSubscriptionIOS
import SummaryKit
import SwiftUI

/// Usage summary (balance and free allowance) above the points ledger, newest first. The ledger
/// loads a page at a time as the list scrolls to its end.
struct PointsUsageView: View {
    let client: Client
    let points: Int?
    let allowance: UsageStatus?

    @State private var entries: [LedgerEntry] = []
    @State private var nextPage: Int? = 1
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadedCount = 0

    private static let pageSize = 20

    var body: some View {
        List {
            Section("Summary") {
                summary
            }
            Section {
                activity
            } header: {
                Text("Activity")
            } footer: {
                Text("Free summaries are used first. After that, each summary takes points, and chat and formatting a summary's source are charged by what the AI model used.")
            }
        }
        .navigationTitle("Usage")
        .summaryInlineNavigationTitle()
        .refreshable { await reload() }
        .task { if entries.isEmpty, nextPage == 1 { await loadNextPage() } }
        .sensoryFeedback(.error, trigger: loadError) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: loadedCount) { old, new in old > 0 && new > old }
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        LabeledContent {
            Text(points.map { String(localized: "\($0.formatted()) points") } ?? "–")
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: points)
        } label: {
            Label("Balance", systemImage: "sparkles")
        }
        .accessibilityIdentifier("usage-balance")
        if let allowance {
            if let limit = allowance.limit {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent {
                        Text("\(min(allowance.used, limit).formatted()) of \(limit.formatted())")
                            .monospacedDigit()
                    } label: {
                        Label("Free summaries used", systemImage: "gift")
                    }
                    ProgressView(value: Double(min(allowance.used, limit)), total: Double(max(limit, 1)))
                        .tint(allowance.remaining == 0 ? .orange : .accentColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("usage-allowance")
            } else {
                LabeledContent {
                    Text("Unlimited")
                } label: {
                    Label("Free summaries", systemImage: "gift")
                }
            }
            if let reset = allowance.resetsAt {
                LabeledContent {
                    Text(reset, format: .relative(presentation: .named))
                } label: {
                    Label("Allowance resets", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    // MARK: Activity

    @ViewBuilder
    private var activity: some View {
        if entries.isEmpty {
            if let loadError {
                ContentUnavailableView {
                    Label("Activity unavailable", systemImage: "wifi.exclamationmark")
                } description: { Text(loadError) } actions: {
                    Button("Try Again") { Task { await loadNextPage() } }
                }
            } else if isLoading || nextPage != nil {
                ProgressView("Loading activity…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                    description: Text("Top-ups and point charges appear here."))
            }
        } else {
            ForEach(entries) { entry in
                LedgerRow(entry: entry)
                    .onAppear {
                        // Infinite scroll: the last row coming into view fetches the next page.
                        if entry.id == entries.last?.id { Task { await loadNextPage() } }
                    }
            }
            if let loadError {
                Button {
                    Task { await loadNextPage() }
                } label: {
                    Label("Couldn't load more. Try again", systemImage: "arrow.clockwise")
                }
                .accessibilityHint(loadError)
            } else if nextPage != nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading more activity")
            }
        }
    }

    private func loadNextPage() async {
        guard let page = nextPage, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.ledger(unit: "points", page: page, pageSize: Self.pageSize)
            // Offset paging: entries added meanwhile shift pages, so skip ones already shown.
            let known = Set(entries.map(\.id))
            entries += result.entries.filter { !known.contains($0.id) }
            nextPage = page < result.pageCount && !result.entries.isEmpty ? page + 1 : nil
            loadError = nil
            loadedCount += 1
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reload() async {
        let fresh: LedgerPage
        do {
            fresh = try await client.ledger(unit: "points", page: 1, pageSize: Self.pageSize)
        } catch {
            loadError = error.localizedDescription
            return
        }
        entries = fresh.entries
        nextPage = 1 < fresh.pageCount ? 2 : nil
        loadError = nil
    }
}

/// One balance movement: what it was for, when, and the points added or taken.
private struct LedgerRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.delta > 0 ? "+\(entry.delta.formatted())" : entry.delta.formatted())
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(entry.delta > 0 ? .green : .primary)
                Text("\(entry.balanceAfter.formatted()) left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var metadataKeys: Set<String> { Set(entry.metadata.map { Array($0.keys) } ?? []) }

    private var title: String {
        switch entry.kind {
        case "topup": return String(localized: "Top-up")
        case "plan_grant": return String(localized: "Points granted")
        case "overage": return String(localized: "Summary", comment: "Ledger entry: points charged for a summary")
        case "refund": return String(localized: "Refund")
        case "dispute": return String(localized: "Payment disputed")
        case "dispute_reversal": return String(localized: "Dispute resolved")
        case "adjustment": return String(localized: "Adjustment")
        case "expiry": return String(localized: "Points expired")
        case "usage":
            if metadataKeys.contains("turnId") { return String(localized: "Chat", comment: "Ledger entry: points charged for a chat turn") }
            if metadataKeys.contains("summaryId") { return String(localized: "Source document") }
            return String(localized: "Usage")
        default: return entry.description.isEmpty ? entry.kind.capitalized : entry.description
        }
    }

    /// The date, plus the model for metered AI charges (the ledger description).
    private var subtitle: String {
        let date = entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard entry.kind == "usage", !entry.description.isEmpty else { return date }
        return "\(date) · \(entry.description)"
    }

    private var symbol: String {
        switch entry.kind {
        case "topup", "plan_grant": "plus"
        case "overage": "doc.text"
        case "refund", "dispute_reversal": "arrow.uturn.backward"
        case "dispute": "exclamationmark.triangle"
        case "expiry": "hourglass"
        case "adjustment": "slider.horizontal.3"
        default: metadataKeys.contains("turnId") ? "bubble.left.and.text.bubble.right" : "doc.plaintext"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case "topup", "plan_grant", "refund", "dispute_reversal": .green
        case "dispute", "expiry": .orange
        case "overage": .blue
        default: .indigo
        }
    }
}
