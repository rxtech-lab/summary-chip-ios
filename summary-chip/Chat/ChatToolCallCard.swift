import SummaryKit
import SwiftUI

/// One agent tool call as a card: what the agent did and with which query, its state, and the
/// summaries it found (tappable). Running calls show a static status.
struct ChatToolCallCard: View, Equatable {
    let tool: ChatToolActivity
    let openSummary: (String) -> Void
    let openTool: (ChatToolActivity) -> Void
    var runQuery: ((String) async throws -> Void)? = nil
    @State private var isRerunning = false
    @State private var rerunError: String?
    @State private var completedRuns = 0
    @Environment(\.openMiniApp) private var openMiniApp

    // Text deltas change the parent entry, but not a completed tool's content.
    // Ignore rebuilt navigation closures so its images and effects stay mounted.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tool == rhs.tool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let runQuery, !tool.isRunning,
               ["queryGraph", "selectGraphElements"].contains(tool.toolName),
               let query = tool.detail, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Spacer()
                    Button {
                        guard !isRerunning else { return }
                        isRerunning = true
                        Task { @MainActor in
                            defer { isRerunning = false }
                            do {
                                try await runQuery(query)
                                completedRuns += 1
                            } catch { rerunError = error.localizedDescription }
                        }
                    } label: {
                        Label("Run Again", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.accentColor)
                    .disabled(isRerunning)
                    .accessibilityIdentifier("chat-query-rerun-\(tool.id)")
                }
            }
            if let draft = tool.miniAppDraft {
                Button { openTool(tool) } label: { Label("Preview \(draft.title)", systemImage: "app.badge") }
            } else if let appID = tool.miniAppID {
                Button {
                    if let openMiniApp { openMiniApp(id: appID, title: "") } else { openSummary(appID) }
                } label: { Label("Open Clip", systemImage: "app.badge") }
            } else if let ui = tool.renderedUI {
                VStack(alignment: .leading, spacing: 12) {
                    Label(ui.title, systemImage: "rectangle.3.group")
                        .font(.subheadline.weight(.semibold))
                    TripViewRenderer(spec: ui.spec, currency: ui.currency)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("chat-rendered-ui-\(tool.id)")
            } else if let sources = tool.webReferences, !sources.isEmpty {
                Button {
                    openTool(tool)
                } label: {
                    Label("View Sources (\(sources.count))", systemImage: "globe")
                        .font(.subheadline.weight(.semibold))
                        .padding(10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("chat-web-sources-\(tool.id)")
            }
            if !tool.references.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(tool.references) { reference in
                            // Open each reference in its dedicated detail sheet.
                            Button {
                                openSummary(reference.id)
                            } label: {
                                ChatReferenceCard(reference: reference)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary) }
        .overlay { if isRerunning { ActionStatusOverlay("Running query…") } }
        .statusAlert("Couldn't Run Query", message: rerunError) { rerunError = nil }
        .sensoryFeedback(.impact(weight: .light), trigger: isRerunning) { _, new in new }
        .sensoryFeedback(.success, trigger: completedRuns)
        .sensoryFeedback(.error, trigger: rerunError) { _, new in new != nil }

    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tool.errorText == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let status {
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var isSearch: Bool { ["searchSummaries", "listTrips", "listEditorsPicks"].contains(tool.toolName) }

    private var symbol: String {
        if tool.errorText != nil { return "exclamationmark.magnifyingglass" }
        switch tool.toolName {
        case "searchWeb": return "globe"
        case "renderUI": return "rectangle.3.group"
        case "searchSummaries": return tool.isSemantic == true ? "sparkle.magnifyingglass" : "magnifyingglass"
        case "listEditorsPicks": return "star.circle"
        case "getSummary": return "doc.text.magnifyingglass"
        case "getRawText": return "doc.plaintext"
        case "listTrips", "getTrip": return "suitcase"
        case "grepLocalFile": return "text.magnifyingglass"
        case "readLocalFile": return "doc.plaintext"
        case "readWebPage": return "globe"
        case "updateTrip": return "suitcase"
        case "updateGraph", "queryGraph", "selectGraphElements", "readGraphElements": return "point.3.connected.trianglepath.dotted"
        default: return "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch tool.toolName {
        case "searchWeb":
            if tool.isRunning { return String(localized: "Searching the web…") }
            if tool.errorText != nil { return String(localized: "Web search unavailable") }
            return tool.finished == true ? String(localized: "Searched the web") : String(localized: "Search stopped")
        case "renderUI":
            if tool.isRunning { return String(localized: "Creating a view…") }
            if tool.errorText != nil { return String(localized: "View needs correction") }
            return tool.renderedUI != nil ? String(localized: "View ready") : String(localized: "View stopped")
        case "searchSummaries":
            if tool.isRunning { return String(localized: "Searching your Feed…") }
            return tool.finished == true ? String(localized: "Searched your Feed") : String(localized: "Search stopped")
        case "listEditorsPicks":
            return tool.isRunning ? String(localized: "Finding Editor’s Picks…") : String(localized: "Editor’s Picks")
        case "getSummary":
            if tool.isRunning { return String(localized: "Reading summary…") }
            return tool.finished == true ? String(localized: "Read summary") : String(localized: "Reading stopped")
        case "getRawText":
            if tool.isRunning { return String(localized: "Reading original text…") }
            return tool.finished == true ? String(localized: "Read original text") : String(localized: "Reading stopped")
        case "listTrips":
            if tool.isRunning { return String(localized: "Finding your trips…") }
            return tool.finished == true ? String(localized: "Listed your trips") : String(localized: "Search stopped")
        case "getTrip":
            if tool.isRunning { return String(localized: "Reading the trip…") }
            return tool.finished == true ? String(localized: "Read the trip") : String(localized: "Reading stopped")
        case "grepLocalFile":
            if tool.isRunning { return String(localized: "Searching the file…") }
            return tool.finished == true ? String(localized: "Searched the file") : String(localized: "Search stopped")
        case "readLocalFile":
            if tool.isRunning { return String(localized: "Reading the file…") }
            return tool.finished == true ? String(localized: "Read the file") : String(localized: "Reading stopped")
        case "updateGraph":
            if tool.isRunning { return String(localized: "Updating the graph…") }
            return tool.errorText != nil ? String(localized: "Edit needs correction") : String(localized: "Updated the graph")
        case "queryGraph":
            if tool.isRunning { return String(localized: "Running the query…") }
            return tool.errorText != nil ? String(localized: "Query needs correction") : String(localized: "Ran a query")
        case "selectGraphElements":
            if tool.isRunning { return String(localized: "Selecting in the graph…") }
            return tool.errorText != nil ? String(localized: "Selection needs correction") : String(localized: "Selected in the graph")
        case "readGraphElements":
            return tool.isRunning ? String(localized: "Reading the graph…") : String(localized: "Read the graph")
        case "readWebPage":
            if tool.isRunning { return String(localized: "Reading the page…") }
            return tool.finished == true ? String(localized: "Read the page") : String(localized: "Reading stopped")
        case "updateTrip":
            if tool.isRunning { return String(localized: "Updating the trip…") }
            if tool.errorText != nil { return String(localized: "Changes needed fixing") }
            return tool.finished == true ? String(localized: "Updated the trip") : String(localized: "Update stopped")
        default:
            if tool.isRunning { return tool.label.isEmpty ? String(localized: "Working…") : tool.label }
            return tool.toolName.isEmpty ? String(localized: "Used a tool") : String(localized: "Used \(tool.toolName)")
        }
    }

    private var detail: String? {
        if let error = tool.errorText { return error }
        if ["getSummary", "getTrip"].contains(tool.toolName) { return tool.references.first?.title }
        return tool.detail
    }

    private var status: String? {
        if tool.toolName == "searchWeb", tool.finished == true, tool.errorText == nil {
            let count = tool.webReferences?.count ?? 0
            return count == 0 ? String(localized: "No web results") : String(localized: "\(count) web sources")
        }
        if let status = tool.status { return status }
        guard isSearch, tool.finished == true else { return nil }
        let count = tool.references.count
        if tool.isSemantic == true {
            return count == 0 ? String(localized: "No matches · by meaning")
                : count == 1 ? String(localized: "1 result · by meaning")
                : String(localized: "\(count) results · by meaning")
        }
        return count == 0 ? String(localized: "No matches") : count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")
    }
}
