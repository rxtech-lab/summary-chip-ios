import SummaryKit
import SwiftUI

/// "+" in the Library: paste a link / text or pick a PDF, choose options, generate, share.
struct NewSummarySheet: View {
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SummaryCreationFlow(
            api: environment.api,
            allowsFilePicking: true,
            onCancel: { dismiss() },
            onCreated: { summary in environment.library.insert(summary) }
        ) { summary in
            NewSummaryResult(environment: environment, summary: summary) { dismiss() }
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
