import AgentMarkdownUI
import AVKit
import SummaryKit
import SwiftUI

/// A rich document: blocks top to bottom, each one or two columns (stacked on compact width), aligned
/// leading, center or trailing, with its links underneath. Agents edit it over MCP; the app reads it
/// and refreshes when it returns to the foreground.
struct RichDocumentDetailView: View {
    let environment: AppEnvironment
    let documentID: String
    let title: String
    @State private var document: RichDocument?
    @State private var errorMessage: String?
    @State private var versions: DocumentVersionsModel
    @State private var sheet: RichDocumentSheet?
    @State private var summary: Summary?
    @State private var status: String?
    @State private var actionError: String?
    @State private var markdown: String?
    @State private var tapFeedback = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(environment: AppEnvironment, documentID: String, title: String = "") {
        self.environment = environment
        self.documentID = documentID
        self.title = title
        _versions = State(initialValue: DocumentVersionsModel(api: environment.api, id: documentID))
    }

    /// The version being previewed, else the current document.
    private var shown: RichDocumentContent? {
        if case .richDocument(let content) = versions.preview?.content { return content }
        return document?.document
    }

    var body: some View {
        content
            .navigationTitle(shown?.title ?? title)
            .summaryInlineNavigationTitle()
            .toolbar { toolbar }
            .task(id: documentID) {
                await load()
                if document?.isOwner == true { await versions.reload() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await load() } }
            }
            .safeAreaInset(edge: .bottom) {
                if versions.isPreviewing { VersionPreviewBanner(model: versions) }
            }
            .documentVersions(versions) { restored in
                guard restored.richDocument != nil else { return }
                Task {
                    await load()
                    if let item = try? await environment.api.summary(id: documentID) { environment.library.upsert(item) }
                }
            }
            .overlay { if let status { ActionStatusOverlay(status) } }
            .statusAlert("Something Went Wrong", message: actionError) { actionError = nil }
            .sensoryFeedback(.selection, trigger: tapFeedback)
            .sheet(item: $sheet) { sheet in sheetContent(sheet) }
    }

    @ViewBuilder
    private var content: some View {
        if let shown {
            ScrollView {
                RichDocumentBlocksView(document: shown)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
            .accessibilityIdentifier("rich-document")
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Document unavailable", systemImage: "doc.text.image")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView("Loading document…")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if document?.isOwner == true {
            ToolbarItem(placement: .automatic) { VersionToolbarMenu(model: versions) }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                Section {
                    Button("Share…", systemImage: "square.and.arrow.up") { openSummarySheet(.share) }
                        .accessibilityIdentifier("rich-document-share")
                    Button("Export Markdown…", systemImage: "text.document") { exportMarkdown() }
                        .accessibilityIdentifier("rich-document-markdown")
                }
                if document?.isOwner == true {
                    Section {
                        Button("Delete Document", systemImage: "trash", role: .destructive) { openSummarySheet(.delete) }
                            .accessibilityIdentifier("rich-document-delete")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .disabled(document == nil)
            .accessibilityIdentifier("rich-document-more")
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: RichDocumentSheet) -> some View {
        switch sheet {
        case .share:
            if let summary {
                ShareModeSheet(summary: summary, api: environment.api) { updated in
                    self.summary = updated
                    environment.library.upsert(updated)
                    Task { await load() }
                }
            }
        case .delete:
            if let summary {
                DeleteSummarySheet(api: environment.api, summary: summary) {
                    environment.library.remove(id: summary.id)
                    dismiss()
                }
            }
        case .markdown:
            if let markdown {
                RichDocumentMarkdownSheet(title: shown?.title ?? title, markdown: markdown)
            }
        }
    }

    private func load() async {
        do {
            document = try await environment.api.richDocument(id: documentID)
            errorMessage = nil
        } catch {
            if document == nil { errorMessage = error.localizedDescription }
        }
    }

    /// Share and delete work on the library item, loaded fresh so its sharing state is current.
    private func openSummarySheet(_ target: RichDocumentSheet) {
        tapFeedback += 1
        Task {
            status = String(localized: "Loading…")
            defer { status = nil }
            do {
                summary = try await environment.api.summary(id: documentID)
                sheet = target
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func exportMarkdown() {
        tapFeedback += 1
        Task {
            status = String(localized: "Preparing Markdown…")
            defer { status = nil }
            do {
                markdown = try await environment.api.richDocumentMarkdown(id: documentID)
                sheet = .markdown
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

enum RichDocumentSheet: String, Identifiable {
    case share, delete, markdown
    var id: String { rawValue }
}

/// The document as Markdown, to read, copy or share.
struct RichDocumentMarkdownSheet: View {
    let title: String
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(markdown)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("Markdown")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: markdown, preview: SharePreview(title)) {
                        Label("Share Markdown", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 480, idealHeight: 640, maxHeight: .infinity)
        #endif
    }
}

/// The blocks, top to bottom.
struct RichDocumentBlocksView: View {
    let document: RichDocumentContent

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if let description = document.description, !description.isEmpty {
                Text(description)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(document.blocks) { block in
                // Block types from a newer server are skipped.
                if case .other = block.type {
                    EmptyView()
                } else {
                    RichBlockView(block: block)
                        .accessibilityIdentifier("rich-block-\(block.id)")
                }
            }
        }
    }
}

struct RichBlockView: View {
    let block: RichBlock
    #if os(iOS) || os(visionOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Two columns sit side by side unless the width is compact.
    private var stacksColumns: Bool {
        #if os(iOS) || os(visionOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var frameAlignment: Alignment {
        switch block.align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch block.align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch block.align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var body: some View {
        VStack(alignment: horizontalAlignment, spacing: 12) {
            columns
            let links = block.children.compactMap(\.link)
            if !links.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: "arrow.up.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    @ViewBuilder
    private var columns: some View {
        if block.columns.count > 1 && !stacksColumns {
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(block.columns.enumerated()), id: \.offset) { _, column in
                    columnView(column).frame(maxWidth: .infinity, alignment: frameAlignment)
                }
            }
        } else {
            VStack(alignment: horizontalAlignment, spacing: 16) {
                ForEach(Array(block.columns.enumerated()), id: \.offset) { _, column in
                    columnView(column).frame(maxWidth: .infinity, alignment: frameAlignment)
                }
            }
        }
    }

    @ViewBuilder
    private func columnView(_ column: RichColumn) -> some View {
        switch block.type {
        case .text:
            MarkdownView(text: column.markdown ?? "", baseURL: nil, style: Self.textStyle)
                .multilineTextAlignment(textAlignment)
                .textSelection(.enabled)
        case .image:
            RichMediaFrame(caption: column.caption, alignment: horizontalAlignment, textAlignment: textAlignment) {
                AsyncImage(url: column.url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Label("Image unavailable", systemImage: "photo")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    default:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(column.alt ?? column.caption ?? "")
            }
        case .video:
            if let url = column.url {
                RichMediaFrame(caption: column.caption, alignment: horizontalAlignment, textAlignment: textAlignment) {
                    RichVideoView(url: url, posterURL: column.posterUrl)
                }
            }
        case .audio:
            if let url = column.url {
                RichMediaFrame(caption: column.caption, alignment: horizontalAlignment, textAlignment: textAlignment) {
                    RichAudioView(url: url, title: column.caption ?? url.lastPathComponent)
                }
            }
        case .other:
            EmptyView()
        }
    }

    private static let textStyle = MarkdownStyle(bodyFontSize: textSize, lineSpacing: 6, blockSpacing: 14, cornerRadius: 10)
    #if os(macOS)
    private static let textSize: CGFloat = 15
    #else
    private static let textSize: CGFloat = 17
    #endif
}

/// Media with its caption underneath.
private struct RichMediaFrame<Media: View>: View {
    let caption: String?
    let alignment: HorizontalAlignment
    let textAlignment: TextAlignment
    @ViewBuilder let media: Media

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            media
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
            }
        }
    }
}

/// A video that loads only when played; the poster, if any, shows until then.
private struct RichVideoView: View {
    let url: URL
    let posterURL: URL?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                Button {
                    let player = AVPlayer(url: url)
                    self.player = player
                    player.play()
                } label: {
                    ZStack {
                        AsyncImage(url: posterURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.black
                        }
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 52))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play Video")
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onDisappear { player?.pause() }
        .sensoryFeedback(.impact(weight: .light), trigger: player != nil)
    }
}

/// A compact audio row: play or pause, and the title.
private struct RichAudioView: View {
    let url: URL
    let title: String
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                let player = self.player ?? AVPlayer(url: url)
                self.player = player
                if isPlaying { player.pause() } else { player.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Label(title, systemImage: "waveform")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 520)
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
        .sensoryFeedback(.selection, trigger: isPlaying)
    }
}
