import SummaryKit
import SwiftUI
import WebKit

struct MarketplaceScreen: View {
    let environment: AppEnvironment
    @State private var selected: Summary?
    @State private var mediaURL: URL?
    @State private var opening = false
    @State private var error: String?
    var body: some View {
        TabView {
            Tab("Discover", systemImage: "safari") { stack(published: false) }
            Tab("Published", systemImage: "person.crop.square") { stack(published: true) }
        }
        .environment(\.summaryAssetLoader, environment.assetLoader)
        // Tabs load lazily, and this also refreshes the user's name on their published cards.
        .task { _ = try? await environment.api.marketplace(mine: true) }
    }

    private func stack(published: Bool) -> some View {
        NavigationStack {
            MarketplaceView(api: environment.api, published: published) { item in
                if item.kind == "podcast" || item.kind == "audiobook" {
                    mediaURL = environment.api.baseURL.appending(path: "podcast/\(item.slug)")
                    return
                }
                let id = item.id
                opening = true
                Task {
                    do { selected = try await environment.api.summary(id: id) }
                    catch { self.error = error.localizedDescription }
                    opening = false
                }
            }
            .sheet(isPresented: Binding(get: { mediaURL != nil }, set: { if !$0 { mediaURL = nil } })) {
                NavigationStack {
                    if let mediaURL { MarketplaceMediaPage(url: mediaURL)
                        .navigationTitle("Published Podcast")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { self.mediaURL = nil } } }
                        .frame(minWidth: 300, minHeight: 500, maxHeight: .infinity)
                    }
                }
            }
            .navigationDestination(item: $selected) { summary in SummaryDestination(environment: environment, summary: summary) }
            .overlay { if opening { ProgressView("Opening…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Could Not Open", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}


#if os(macOS)
private struct MarketplaceMediaPage: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: url)); return view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct MarketplaceMediaPage: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: url)); return view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
