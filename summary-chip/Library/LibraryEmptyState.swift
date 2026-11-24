import SummaryKit
import SwiftUI

struct LibraryEmptyState: View {
    let model: LibraryModel
    let isMiniApps: Bool
    let createClip: () -> Void
    let createSummary: () -> Void

    @ViewBuilder
    var body: some View {
        if model.isOffline {
            ContentUnavailableView {
                Label("You're offline", systemImage: "wifi.slash")
            } description: {
                !model.filter.isActive
                    ? Text("Summaries you open while online are saved on this device for offline reading.")
                    : Text("No saved summaries match. Connect to the internet to search your whole library.")
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label(isMiniApps ? String(localized: "Couldn't load your clips") : String(localized: "Couldn't load your Feed"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        } else if model.filter.isActive {
            ContentUnavailableView(
                isMiniApps ? String(localized: "No Matching Clips") : String(localized: "No Matching Summaries"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(isMiniApps ? String(localized: "No clips match the current filters.") : String(localized: "No summaries match the current filters."))
            )
        } else if isMiniApps {
            ContentUnavailableView {
                Label("No clips yet", systemImage: "app.badge")
            } description: {
                Text("Create a clip or ask Chat to build one. Your saved clips appear here.")
            } actions: {
                Button("New Clip") { createClip() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("create-first-mini-app")
            }
        } else {
            ContentUnavailableView {
                Label("No summaries yet", systemImage: "text.quote")
            } description: {
                Text("Summaries you create, and ones you open from shared links, appear here. Share a web page, PDF or text to Chippy, or paste a link.")
            } actions: {
                Button("New Summary") { createSummary() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
