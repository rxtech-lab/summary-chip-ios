import SummaryKit
import SwiftUI

/// "+" in the Library: paste a link / text or choose a local document, then generate and share.
/// Also opened with a file or link dropped on the window or opened with the app.
struct NewSummarySheet: View {
    let environment: AppEnvironment
    var initialText = ""
    var initialFile: DroppedSummaryFile?
    @Environment(\.dismiss) private var dismiss
    @State private var showsTopUp = false

    var body: some View {
        SummaryCreationFlow(
            api: environment.api,
            initialText: initialText,
            initialFile: initialFile,
            allowsFilePicking: true,
            onCancel: { dismiss() },
            onCreated: { summary in
                environment.library.insert(summary)
                Task { await environment.credits.refresh(api: environment.api, broker: environment.tokenBroker) }
            },
            onTopUp: { showsTopUp = true },
            freeSummariesRemaining: environment.credits.allowance?.remaining
        ) { summary in
            NewSummaryResult(environment: environment, summary: summary) { dismiss() }
        }
        .task { await environment.credits.refresh(api: environment.api, broker: environment.tokenBroker) }
        .sheet(isPresented: $showsTopUp) {
            SummaryCreditsSheet(environment: environment, opensTopUps: true)
        }
    }
}

private struct NewSummaryResult: View {
    let environment: AppEnvironment
    let summary: Summary
    let onDone: () -> Void

    var body: some View {
        List {
            Section {
                SummaryCardView(summary: summary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
            }
            ShareActionsSection(summary: summary)
            Section {
                NavigationLink(value: summary) {
                    Label("View summary", systemImage: "doc.text")
                }
            }
        }
        .navigationDestination(for: Summary.self) { summary in
            SummaryDetailView(environment: environment, summary: summary)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone).fontWeight(.semibold)
            }
        }
    }
}
