import Messages
import SummaryKit
import SwiftUI

struct MessagesRootView: View {
    let state: MessagesState

    var body: some View {
        Group {
            switch state.isSignedIn {
            case .none:
                ProgressView()
            case .some(false):
                SignedOutNotice {
                    state.openApp(URL(string: "\(SummaryIdentifiers.urlScheme)://")!)
                }
            case .some(true):
                if state.presentationStyle == .compact {
                    CompactMessagesView(state: state)
                } else {
                    SummaryCreationFlow(
                        api: state.api,
                        initialText: state.pendingText,
                        title: "New Summary",
                        onCancel: { state.requestStyle(.compact) },
                        onCreated: { state.created($0) }
                    ) { summary in
                        MessagesSendView(state: state, summary: summary)
                    }
                    .id(state.flowID)
                }
            }
        }
    }
}

private struct CompactMessagesView: View {
    let state: MessagesState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PasteButton(payloadType: URL.self) { urls in
                    guard let url = urls.first else { return }
                    Task { @MainActor in state.startNew(with: url.absoluteString) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                Button {
                    state.startNew()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                Spacer()
            }
            if state.recent.isEmpty {
                Text(state.recentError ?? "Your recent summaries appear here. Paste a link to create one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(state.recent) { summary in
                            Button {
                                state.insertLink(summary.shareUrl)
                            } label: {
                                SummaryCardView(summary: summary, compact: true)
                                    .frame(width: 190)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Sends the link")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }
}

private struct MessagesSendView: View {
    let state: MessagesState
    let summary: Summary

    @Environment(\.summaryAssetLoader) private var loader
    @State private var isPreparingImage = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                SummaryCardView(summary: summary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
            }
            Section {
                Button {
                    state.insertLink(summary.shareUrl)
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Send as link")
                            Text("Messages shows the rich preview.").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "link")
                    }
                }
                Button {
                    Task { await sendImage() }
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Send as image")
                            Text("The preview image followed by the link.").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        if isPreparingImage { ProgressView() } else { Image(systemName: "photo") }
                    }
                }
                .disabled(isPreparingImage)
            } footer: {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
    }

    private func sendImage() async {
        isPreparingImage = true
        defer { isPreparingImage = false }
        do {
            let file = try await loader.downloadOGImage(for: summary)
            state.insertImage(file, summary.shareUrl)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
