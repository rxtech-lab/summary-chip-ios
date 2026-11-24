import SummaryKit
import SwiftUI

/// The page a library item opens: a trip diary for trips, the LaTeX editor for papers, the summary detail otherwise.
struct SummaryDestination: View {
    let environment: AppEnvironment
    let summary: Summary
    var allowsChat = true
    var onOpenTrip: ((Summary) -> Void)?
    var onUpdate: ((Summary) -> Void)?

    var body: some View {
        if summary.kind == .trip {
            TripDetailView(
                environment: environment,
                tripID: summary.id,
                title: summary.title,
                onOpenTrip: onOpenTrip.map { action in { action(summary) } }
            )
        } else if summary.kind == .miniApp {
            MiniAppDetailView(environment: environment, appID: summary.id, title: summary.title)
        } else if summary.kind == .graph {
            #if os(visionOS)
            SpatialGraphLauncher(graphID: summary.id)
            #else
            GraphDetailView(environment: environment, graphID: summary.id, title: summary.title)
            #endif
        } else if summary.kind == .todoList {
            TodoDetailView(environment: environment, id: summary.id)
        } else if summary.kind == .resume {
            ResumeDetailView(environment: environment, id: summary.id)
        } else if summary.kind == .richDocument {
            RichDocumentDetailView(environment: environment, documentID: summary.id, title: summary.title)
        } else if (summary.kind == .podcast || summary.kind == .audiobook) {
            LibraryPodcastDetail(environment: environment, summary: summary)
        } else if summary.kind == .paper {
            PaperDetailView(environment: environment, paperID: summary.id, title: summary.title)
        } else {
            SummaryDetailView(environment: environment, summary: summary, allowsChat: allowsChat, onUpdate: onUpdate)
        }
    }
}

/// Loads a summary by id, then shows its detail (chat result cards, "Open in app").
struct SummaryLoaderView: View {
    let environment: AppEnvironment
    let id: String
    var allowsChat = true
    var onOpenTrip: ((Summary) -> Void)?
    @State private var summary: Summary?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let summary {
                SummaryDestination(environment: environment, summary: summary, allowsChat: allowsChat, onOpenTrip: onOpenTrip)
            } else if let errorMessage {
                ContentUnavailableView("Summary unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .task(id: id) {
            do {
                let fresh = try await environment.api.summary(id: id)
                environment.library.upsert(fresh)
                summary = fresh
            } catch let error as SummaryAPIError where error.isNotFound {
                environment.library.remove(id: id)
                errorMessage = error.localizedDescription
            } catch {
                // Offline (or the server is down): show the copy saved on this device.
                if let saved = environment.library.offline.summary(id: id) {
                    summary = saved
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// Presented for universal links (`/s/<slug>`), `summarychip://summary/<id>` and `summarychip://trip/<id>`.
/// "Open in Feed" closes the sheet and shows the item in the main navigation via `onOpen`.
struct DeepLinkSheet: View {
    let environment: AppEnvironment
    let route: AppRoute
    var onOpen: ((Summary) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var summary: Summary?
    @State private var publishedResume: ResumePublication?
    @State private var expiredLike: Summary?
    @State private var errorMessage: String?
    @State private var openCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if case .slug(let slug) = route, let publishedResume {
                    ResumeRecipientView(api: environment.api, slug: slug, publication: publishedResume)
                } else if case .tripID(let id) = route {
                    TripDetailView(environment: environment, tripID: id, title: summary?.title ?? "")
                } else if let summary {
                    // Keep the copy current so "Open in Feed" carries a star made here.
                    SummaryDestination(environment: environment, summary: summary, onUpdate: { self.summary = $0 })
                } else if let expiredLike {
                    ExpiredSummaryView(environment: environment, summary: expiredLike)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Summary unavailable", systemImage: "link.badge.plus")
                    } description: {
                        Text(errorMessage)
                    }
                } else {
                    ProgressView("Opening summary…")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let onOpen, let summary {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            openCount += 1
                            onOpen(summary)
                        } label: {
                            Label(summary.kind == .trip ? "Open Trip" : summary.kind == .miniApp ? "Open Clip" : "Open in Feed", systemImage: "arrow.up.right.square")
                        }
                        .help(summary.kind == .trip ? "Open Trip" : summary.kind == .miniApp ? "Open Clip" : "Open in Feed")
                        .accessibilityIdentifier("deep-link-open")
                    }
                }
            }
        }
        .task(id: route) { await load() }
        .sensoryFeedback(.impact(weight: .light), trigger: openCount)
    }

    private func load() async {
        if case .tripID(let id) = route {
            // The diary loads itself; its library item is only needed to open it in the Library.
            summary = environment.library.items.first { $0.id == id } ?? environment.likes.items.first { $0.id == id }
            if summary == nil { summary = try? await environment.api.summary(id: id) }
            return
        }
        do {
            let fresh: Summary
            switch route {
            case .slug(let slug):
                // Records the view (it then appears in the library as "Viewed") and returns the summary.
                do { fresh = try await environment.api.recordView(slug: slug) }
                catch let original as SummaryAPIError where original.isNotFound {
                    publishedResume = try await environment.api.resumePublication(slug: slug)
                    return
                }
            case .summaryID(let id), .tripID(let id):
                fresh = try await environment.api.summary(id: id)
            }
            environment.library.upsert(fresh)
            environment.likes.upsert(fresh)
            summary = fresh
        } catch let error as SummaryAPIError where error.isNotFound {
            if let saved { environment.library.remove(id: saved.id) }
            // A summary in Likes stays there after its link expires; show it as expired.
            if var liked = likedCopy {
                liked.isExpired = true
                expiredLike = liked
            } else {
                errorMessage = String(localized: "This summary is private, its link has expired, or it was deleted.")
            }
        } catch {
            // Offline (or the server is down): show the copy saved on this device.
            if let saved {
                summary = saved
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var saved: Summary? {
        switch route {
        case .slug(let slug): environment.library.offline.summary(slug: slug).flatMap { $0.kind == .resume ? nil : $0 }
        case .summaryID(let id), .tripID(let id): environment.library.offline.summary(id: id)
        }
    }

    private var likedCopy: Summary? {
        switch route {
        case .slug(let slug): environment.likes.items.first { $0.slug == slug && $0.kind != .resume }
        case .summaryID(let id), .tripID(let id): environment.likes.items.first { $0.id == id }
        }
    }
}

private struct LibraryPodcastDetail: View {
    let environment: AppEnvironment
    let summary: Summary
    @State private var podcast: DailyPodcast?
    @State private var loading = true
    @State private var openingChip = false
    @State private var showsRegeneration = false
    @State private var xSharingRequest: XSharingRequest?
    @State private var showsLinkedChips = false
    @State private var pendingChipID: String?
    @State private var regenerations = 0
    @State private var error: String?
    var body: some View {
        Group {
            if let podcast {
                DailyPodcastPlaybackView(api: environment.api, podcast: podcast,
                    player: environment.podcastPlayer, onOpenChip: openChip)
            } else if !loading {
                ContentUnavailableView {
                    Label("Podcast Unavailable", systemImage: "waveform")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if loading || openingChip {
                ProgressView(openingChip ? "Opening chip…" : "Loading podcast…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .xSharing($xSharingRequest, api: environment.api)
        .navigationTitle(podcast?.title ?? summary.title)
        .toolbar {
            if let podcast {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Share", systemImage: "square.and.arrow.up") {
                        Button("Share to X", systemImage: "arrow.up.forward") {
                            xSharingRequest = XSharingRequest(podcast: podcast)
                        }
                        .accessibilityIdentifier("podcast-share-x")
                    }
                }
            }
            if let podcast, !podcast.sourceChipIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Linked Chips", systemImage: "doc.on.doc") { showsLinkedChips = true }
                        .accessibilityIdentifier("podcast-linked-chips")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Regenerate Podcast", systemImage: "arrow.clockwise") { showsRegeneration = true }
                    .help("Regenerate Podcast")
                    .disabled(podcast == nil)
                    .accessibilityIdentifier("library-podcast-regenerate")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Podcast Options", systemImage: "ellipsis") { environment.podcastPlayer.isPresented = true }
                    .disabled(podcast == nil)
            }
        }
        .sheet(isPresented: $showsLinkedChips, onDismiss: {
            if let id = pendingChipID { pendingChipID = nil; openChip(id) }
        }) {
            PodcastLinkedChipsSheet(api: environment.api, chipIDs: podcast?.sourceChipIDs ?? []) { id in
                pendingChipID = id
                showsLinkedChips = false
            }
        }
        .sensoryFeedback(.selection, trigger: showsLinkedChips)
        .sheet(isPresented: $showsRegeneration) {
            if let podcast {
                // Adds a new version to this chip; earlier versions stay in Manage Versions.
                DailyPodcastGenerationSheet(api: environment.api, date: environment.podcastPlayer.date ?? Date(), existing: podcast, library: true) { regenerated in
                    regenerations += 1
                    show(regenerated)
                    // The chip's title and cover are redrawn with the new version.
                    Task { if let chip = try? await environment.api.summary(id: summary.id) { environment.library.upsert(chip) } }
                }
            }
        }
        .sensoryFeedback(.success, trigger: regenerations)
        .task { await load() }
        .onDisappear {
            if environment.podcastPlayer.inlinePodcastKey == podcast?.key { environment.podcastPlayer.inlinePodcastKey = nil }
        }
        .alert("Couldn't Open Podcast", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func openChip(_ id: String) {
        openingChip = true
        Task {
            defer { openingChip = false }
            do { environment.pendingLibraryItem = try await environment.api.summary(id: id) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let saved = try await environment.api.libraryPodcast(summaryID: summary.id)
            try Task.checkCancellation()
            show(saved)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func show(_ saved: DailyPodcast) {
        podcast = saved
        environment.podcastPlayer.inlinePodcastKey = saved.key
        if environment.podcastPlayer.podcast?.key != saved.key || environment.podcastPlayer.podcast?.video?.id != saved.video?.id {
            environment.podcastPlayer.replace(saved)
            environment.podcastPlayer.date = saved.day.flatMap { ISO8601DateFormatter().date(from: $0.start) } ?? Date()
        }
    }
}
