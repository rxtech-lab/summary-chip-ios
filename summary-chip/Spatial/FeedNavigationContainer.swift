import SummaryKit
import SwiftUI

/// Spatial feeds sit directly in the plain window; only their detail sheets own navigation chrome.
struct FeedNavigationContainer<Content: View>: View {
    let environment: AppEnvironment
    @Binding var path: [Summary]
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(visionOS)
        content()
            .sheet(isPresented: Binding(
                get: { !path.isEmpty },
                set: { if !$0 { path.removeAll() } }
            )) {
                if let summary = path.first {
                    NavigationStack {
                        Group {
                            if summary.isExpired {
                                ExpiredSummaryView(environment: environment, summary: summary)
                            } else {
                                SummaryDestination(environment: environment, summary: summary)
                            }
                        }
                        .navigationDestination(for: Summary.self) { item in
                            SummaryDestination(environment: environment, summary: item)
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { path.removeAll() }
                            }
                        }
                    }
                    .frame(minWidth: 700, minHeight: 600)
                }
            }
        #else
        NavigationStack(path: $path) { content() }
        #endif
    }
}
