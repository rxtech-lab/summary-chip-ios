#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

public struct MarketplaceView: View {
    let api: SummaryAPIClient
    let author: String?
    /// Lists the signed-in user's own publications, each with a way to unpublish it.
    let published: Bool
    let onOpen: ((MarketplaceItem) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var items: [MarketplaceItem] = []
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var followed = Set<String>()
    @State private var changingFollow = false
    @State private var feedback = 0
    @State private var followEditor = false
    @State private var selectedAuthor: String?
    @State private var ownAuthors = Set<String>()
    private var editingAuthor: String? { selectedAuthor ?? author }
    @State private var unpublishing: MarketplaceItem?
    @State private var status: String?
    public init(api: SummaryAPIClient, author: String? = nil, published: Bool = false, onOpen: ((MarketplaceItem) -> Void)? = nil) { self.api = api; self.author = author; self.published = published; self.onOpen = onOpen }
    public var body: some View {
        Group {
            if loading && items.isEmpty {
                ProgressView("Loading Discover…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ScrollView { emptyState }
            } else {
                feed
            }
        }
        .background(.background)
        .navigationTitle(published ? "Published" : (author == nil ? "Discover" : "Author"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            #if !os(macOS)
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            #endif
            if let author, !ownAuthors.contains(author) {
                ToolbarItem(placement: .primaryAction) {
                    Button { selectedAuthor = author; followEditor = true } label: {
                        Label(followed.contains(author) ? "Following" : "Follow Author", systemImage: followed.contains(author) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                    }
                }
            }
            if author == nil && !published && !followed.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        List(followed.sorted(), id: \.self) { id in
                            NavigationLink(items.first { $0.authorId == id }?.authorName ?? "Chippy author") {
                                MarketplaceView(api: api, author: id, onOpen: onOpen)
                            }
                        }.navigationTitle("Following")
                    } label: { Label("Following", systemImage: "person.2").labelStyle(.iconOnly) }
                    .help("Following")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .help("Refresh")
                    .disabled(loading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openURL(api.baseURL.appending(path: "discover"))
                } label: {
                    Label("Open in Web", systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Open in Web")
                .help("Open in Web")
            }
        }
        .task {
            await load()
            guard !published, !Task.isCancelled else { return }
            do {
                followed = try await api.followedAuthors()
                let own = try await api.marketplace(mine: true)
                ownAuthors = Set(own.items.map(\.authorId))
            }
            catch { reportLoadingError(error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .authorFollowingChanged)) { _ in
            Task {
                do { followed = try await api.followedAuthors() }
                catch { reportLoadingError(error) }
            }
        }
        .refreshable { await load() }
        .alert("Discover", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .sheet(isPresented: $followEditor) {
            NavigationStack {
                Form {
                    Text("Follow this author to see their published chips in your Feed.")
                    if let name = items.first(where: { $0.authorId == editingAuthor })?.authorName {
                        Label(name, systemImage: "person.crop.circle").font(.headline)
                    }
                    Button(followed.contains(editingAuthor ?? "") ? "Unfollow" : "Follow") {
                        guard let author = editingAuthor else { return }
                        changingFollow = true
                        Task {
                            do {
                                let following = !followed.contains(author)
                                try await api.followAuthor(author, following: following)
                                if following { followed.insert(author) } else { followed.remove(author) }
                                feedback += 1; followEditor = false
                            } catch { self.error = error.localizedDescription }
                            changingFollow = false
                        }
                    }.disabled(changingFollow)
                }
                .navigationTitle("Follow Author")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { followEditor = false }.disabled(changingFollow) } }
                .overlay { if changingFollow { ProgressView("Saving…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                .frame(minWidth: 300, minHeight: 300, maxHeight: .infinity)
            }
            .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
            .interactiveDismissDisabled(changingFollow)
        }
        .confirmationDialog("Unpublish from Discover?", isPresented: Binding(get: { unpublishing != nil }, set: { if !$0 { unpublishing = nil } }), titleVisibility: .visible, presenting: unpublishing) { item in
            Button("Unpublish", role: .destructive) { Task { await unpublish(item) } }
        } message: { _ in
            Text("It will no longer appear in Discover. Its share link stays active; change that from its sharing settings.")
        }
        .overlay { if let status { ActionStatusOverlay(status) } }
        .sensoryFeedback(.selection, trigger: followEditor)
        .sensoryFeedback(.success, trigger: feedback)
        .sensoryFeedback(.error, trigger: error)
    }
    private var feed: some View {
        SummaryCardFeed(
            entries: items.map { SummaryFeedEntry(summary: $0.chip, date: $0.publishedAt, dateKind: .created) },
            header: AnyView(introduction.padding(.horizontal, 16).padding(.vertical, 8)),
            onReachEnd: { if let nextOffset { Task { await load(offset: nextOffset) } } },
            onSelect: { summary in if let item = items.first(where: { $0.id == summary.id }) { open(item) } },
            tileFooter: { summary in AnyView(tileFooter(for: summary)) },
            menuItems: { summary in
                if published, let item = items.first(where: { $0.id == summary.id }) {
                    Button("Unpublish…", systemImage: "eye.slash", role: .destructive) { unpublishing = item }
                }
            },
            footer: {
                if loading { ProgressView().controlSize(.small).padding() }
            }
        )
    }

    @ViewBuilder
    private func tileFooter(for summary: Summary) -> some View {
        if let item = items.first(where: { $0.id == summary.id }) {
            if published { publicationRow(item) } else { authorRow(item) }
        }
    }

    private func authorRow(_ item: MarketplaceItem) -> some View {
        HStack(spacing: 8) {
            NavigationLink {
                MarketplaceView(api: api, author: item.authorId, onOpen: onOpen)
            } label: {
                Label(item.authorName ?? "Chippy author", systemImage: "person.crop.circle.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if !ownAuthors.contains(item.authorId) {
                Button {
                    selectedAuthor = item.authorId
                    followEditor = true
                } label: {
                    Text(followed.contains(item.authorId) ? "Following" : "Follow")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(followed.contains(item.authorId) ? .secondary : .accentColor)
                .accessibilityLabel("\(followed.contains(item.authorId) ? "Following" : "Follow") \(item.authorName ?? "Chippy author")")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
    }

    private func publicationRow(_ item: MarketplaceItem) -> some View {
        HStack(spacing: 8) {
            if isListed(item.chip) {
                Label("In Discover", systemImage: "globe").foregroundStyle(.secondary)
            } else {
                Label("Hidden from Discover", systemImage: "eye.slash").foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button("Unpublish", role: .destructive) { unpublishing = item }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("unpublish-\(item.id)")
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
    }

    /// Discover only lists public chips whose link hasn't expired.
    private func isListed(_ chip: Summary) -> Bool {
        chip.visibility == .public && !(chip.expiresAt.map { $0 <= .now } ?? false)
    }

    private func open(_ item: MarketplaceItem) {
        if let onOpen { onOpen(item); return }
        openURL(api.baseURL.appending(path: "\(["podcast", "audiobook"].contains(item.kind) ? "podcast" : "s")/\(item.slug)"))
    }

    private func unpublish(_ item: MarketplaceItem) async {
        status = String(localized: "Unpublishing…")
        defer { status = nil }
        do {
            try await api.publishToMarketplace(summaryID: item.id, published: false)
            items.removeAll { $0.id == item.id }
            feedback += 1
        } catch { self.error = error.localizedDescription }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(published ? "Your published content" : (author == nil ? "Discover something worth keeping." : "Published by this author"))
                .font(.title2.weight(.semibold))
            Text(published ? "Everything you've shared with the Chippy community." : (author == nil ? "Explore ideas, stories, and creations from the Chippy community." : "Browse their latest shared work."))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "safari")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.indigo)
                .frame(width: 88, height: 88)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))
            VStack(spacing: 8) {
                Text(published ? "Nothing published yet" : (author == nil ? "A place for good ideas" : "No publications yet"))
                    .font(.title2.weight(.semibold))
                Text(published
                     ? "Choose Publish to Discover in a chip's share sheet, and it will appear here."
                     : author == nil
                     ? "Published chips will appear here. Share one from your library to start the collection."
                     : "When this author publishes something, you’ll find it here.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            Button { Task { await load() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func load(offset: Int = 0) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.marketplace(author: author, mine: published, offset: offset)
            if offset == 0 { items = page.items } else { items += page.items.filter { item in !items.contains { $0.id == item.id } } }
            nextOffset = page.nextOffset
        } catch { reportLoadingError(error) }
    }

    private func reportLoadingError(_ error: Error) {
        // View lifecycle and refresh cancellation are expected, not failures to show.
        guard !Task.isCancelled,
              !(error is CancellationError),
              (error as? URLError)?.code != .cancelled else { return }
        self.error = error.localizedDescription
    }
}

public struct MarketplacePublishingSheet: View {
    let api: SummaryAPIClient
    let summaryID: String?
    let podcastKey: String?
    let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var removing = false
    @State private var error: String?
    @State private var feedback = 0
    public init(api: SummaryAPIClient, summaryID: String? = nil, podcastKey: String? = nil, embedded: Bool = false) { self.api = api; self.summaryID = summaryID; self.podcastKey = podcastKey; self.embedded = embedded }
    @ViewBuilder
    public var body: some View {
        if embedded { publishingContent } else { NavigationStack { publishingContent } }
    }

    private var publishingContent: some View {
        Group {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "globe")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.tint)
                                .frame(width: 64, height: 64)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Share with everyone").font(.title2.weight(.semibold))
                                Text("Share your content with the Chippy community in Discover.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 18) {
                                publishingDetail("Public access", detail: "Anyone can find and open this content on the web and in the app.", symbol: "person.2")
                                Divider()
                                publishingDetail("Published under your name", detail: "Your author name appears alongside your content.", symbol: "person.crop.circle")
                                Divider()
                                publishingDetail("No expiry date", detail: "Your content stays public until you change its sharing settings.", symbol: "calendar")
                            }.padding(12)
                        }
                        if podcastKey != nil {
                            Label("This episode becomes a library podcast that people can discover and play.", systemImage: "waveform")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Remove an existing listing") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Removing a listing leaves its public share link active. To make the content private, change its link settings separately.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Remove from Discover", role: .destructive) { removing = true }
                            }.padding(.top, 12)
                        }
                    }.padding(24)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Publish") { save(true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }.padding(20)
            }
            .disabled(busy)
            .navigationTitle("Publish to Discover")
            .summaryInlineNavigationTitle()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay { if busy { ProgressView("Saving…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 540, minHeight: 540, idealHeight: 580)
        #endif
        .interactiveDismissDisabled(busy).sensoryFeedback(.success, trigger: feedback)
        .sensoryFeedback(.error, trigger: error)
        .confirmationDialog("Remove from Discover?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { save(false) }
        } message: { Text("This item will no longer appear in Discover.") }
    }

    private func publishingDetail(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func save(_ published: Bool) {
        busy = true
        Task {
            do { try await api.publishToMarketplace(summaryID: summaryID, podcastKey: podcastKey, published: published); feedback += 1; dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
#endif
