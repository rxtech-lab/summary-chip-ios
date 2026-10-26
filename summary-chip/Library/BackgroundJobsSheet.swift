import SummaryKit
import SwiftUI

struct BackgroundJobsSheet: View {
    let api: SummaryAPIClient
    var selectedID: String?
    let onOpenPodcast: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var jobs: [BackgroundJob] = []
    @State private var path: [String] = []
    @State private var cursor: String?
    @State private var loading = true
    @State private var refreshing = false
    @State private var error: String?
    @State private var taps = 0
    @State private var showsNotifications = false
    @State private var pendingDeletion: BackgroundJob?
    @State private var deleting = false
    @State private var deletedIDs: Set<String> = []
    @State private var deletionError: String?
    @State private var deletions = 0
    @State private var showsDeleted = false

    var body: some View {
        NavigationStack(path: $path) {
            jobsList
            .overlay(alignment: .bottom) {
                if showsDeleted {
                    Label("Job log deleted", systemImage: "checkmark.circle.fill")
                        .padding().background(.regularMaterial, in: Capsule()).padding()
                        .accessibilityIdentifier("background-job-deleted")
                }
            }
            .disabled(deleting)
            .overlay {
                if deleting {
                    ProgressView("Deleting job log…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                } else if loading && jobs.isEmpty { ProgressView("Loading jobs…") }
                else if jobs.isEmpty && error == nil {
                    ContentUnavailableView("No Background Jobs", systemImage: "clock.arrow.circlepath",
                        description: Text("Video script jobs appear here. You can close the app while the server works."))
                }
            }
            .navigationTitle("Background Jobs")
            .summaryInlineNavigationTitle()
            .navigationDestination(for: String.self) { id in
                BackgroundJobDetail(api: api, id: id, onOpenPodcast: onOpenPodcast)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { taps += 1; showsNotifications = true } label: { Label("Notifications", systemImage: "bell") }
                }
            }
            .refreshable { await reload() }
            .sheet(isPresented: $showsNotifications) { NotificationSettingsSheet() }
            .task { if let selectedID { path = [selectedID] } }
            .task(id: deletions) {
                guard deletions > 0 else { return }
                showsDeleted = true
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                showsDeleted = false
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await reload()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                } while !Task.isCancelled
            }
            .alert("Couldn't Load Jobs", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .alert("Delete Job Log?", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            )) {
                if let job = pendingDeletion {
                    Button("Delete Job Log", role: .destructive) { Task { await delete(job) } }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This permanently removes this job's history and logs. Your podcast is kept, and any generation in progress continues.")
            }
            .alert("Couldn't Delete Job Log", isPresented: Binding(
                get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK", role: .cancel) { deletionError = nil }
            } message: { Text(deletionError ?? "") }
            .sensoryFeedback(.selection, trigger: path)
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.error, trigger: error)
            .sensoryFeedback(.error, trigger: deletionError)
            .sensoryFeedback(.success, trigger: deletions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 320, idealWidth: 580, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private var jobsList: some View {
        List {
            ForEach(jobs) { job in
                NavigationLink(value: job.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.title).font(.headline)
                        Label(job.statusTitle, systemImage: job.statusIcon).font(.subheadline).foregroundStyle(.secondary)
                        if let failure = job.error { Text(failure.message).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        if job.status == "running" { ProgressView(value: Double(job.percent), total: 100) }
                        Text(job.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                .accessibilityIdentifier("background-job-\(job.id)")
                #if os(macOS)
                .contextMenu {
                    Button("Delete Job Log", systemImage: "trash", role: .destructive) { confirmDeletion(job) }
                }
                #else
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDeletion(job) }
                }
                #endif
            }
            if cursor != nil { Button("Load More") { Task { await reload(more: true) } }.disabled(refreshing) }
        }
    }

    private func confirmDeletion(_ job: BackgroundJob) {
        taps += 1
        pendingDeletion = job
    }

    private func delete(_ job: BackgroundJob) async {
        guard !deleting else { return }
        deleting = true
        pendingDeletion = nil
        do {
            try await api.deleteBackgroundJob(id: job.id)
            deletedIDs.insert(job.id)
            jobs.removeAll { $0.id == job.id }
            path.removeAll { $0 == job.id }
            cursor = nil
            deletions += 1
        } catch { deletionError = error.localizedDescription }
        deleting = false
        await reload()
    }

    private func reload(more: Bool = false) async {
        guard !refreshing, !deleting else { return }
        refreshing = true
        defer { refreshing = false; loading = false }
        do {
            let page = try await api.backgroundJobs(cursor: more ? cursor : nil)
            var items = page.items
            var next = page.nextCursor
            // Refresh every already-loaded page so removed episodes disappear too.
            if !more {
                while let token = next, items.count < jobs.count {
                    let following = try await api.backgroundJobs(cursor: token)
                    items += following.items
                    next = following.nextCursor
                }
            }
            try Task.checkCancellation()
            // A poll already in flight must not restore a deleted row or cursor.
            items.removeAll { deletedIDs.contains($0.id) }
            if let token = next, deletedIDs.contains(token) { next = items.last?.id }
            if more { jobs += items.filter { item in !jobs.contains(where: { $0.id == item.id }) } }
            else { jobs = items }
            cursor = next
            error = nil
        } catch is CancellationError { return }
        catch { if self.error == nil { self.error = error.localizedDescription } }
    }
}

private struct BackgroundJobDetail: View {
    let api: SummaryAPIClient
    let id: String
    let onOpenPodcast: (DailyPodcast) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var job: BackgroundJob?
    @State private var error: String?
    @State private var opening = false
    @State private var renderEpisode: DailyPodcast?
    @State private var showsRender = false
    @State private var taps = 0

    var body: some View {
        List {
            if let job {
                Section {
                    Text(job.title).font(.headline)
                    Label(job.statusTitle, systemImage: job.statusIcon)
                    if job.status == "running" {
                        ProgressView(value: Double(job.percent), total: 100)
                        Text("You can close this sheet or quit the app. Script writing continues on the server.")
                    } else if job.status == "ready" {
                        Button("Render on This Device", systemImage: "play.rectangle") { open(render: true) }
                            .accessibilityIdentifier("background-job-render")
                        Text("Keep the app open during rendering. The finished video is cached on this device.")
                    } else { Text("Open the podcast and choose Generate Video or Regenerate to try again.") }
                    Button("Open Podcast", systemImage: "waveform") { open(render: false) }
                }
                if let failure = job.error {
                    Section("Error") {
                        Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                        Text(failure.code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Section("Live Activity Log") {
                    ForEach(job.logs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.message).textSelection(.enabled)
                            Text(entry.at, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Job Details")
        .summaryInlineNavigationTitle()
        .disabled(opening)
        .overlay {
            if opening || job == nil && error == nil {
                ProgressView(opening ? "Opening podcast…" : "Loading job…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .sheet(isPresented: $showsRender) {
            if let renderEpisode { BackgroundVideoRenderSheet(api: api, podcast: renderEpisode) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            repeat {
                do {
                    job = try await api.backgroundJob(id: id)
                    if job?.status != "running" { return }
                    try await Task.sleep(for: .seconds(3))
                } catch is CancellationError { return }
                catch { self.error = error.localizedDescription; return }
            } while !Task.isCancelled
        }
        .alert("Couldn't Open Job", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .sensoryFeedback(.selection, trigger: taps)
        .sensoryFeedback(.success, trigger: job?.status == "ready")
        .sensoryFeedback(.error, trigger: error)
    }

    private func open(render: Bool) {
        guard let job, !opening else { return }
        taps += 1
        opening = true
        Task {
            defer { opening = false }
            do {
                let podcast = try await api.backgroundJobPodcast(job)
                if render {
                    guard let videoID = job.videoId, podcast.video?.id == videoID, !podcast.isDesigningVideo else {
                        self.error = String(localized: "This script was replaced by a newer design. Open the latest job or the podcast to continue.")
                        return
                    }
                    renderEpisode = podcast
                    showsRender = true
                } else { onOpenPodcast(podcast) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension BackgroundJob {
    var statusTitle: String {
        switch status {
        case "running": "Writing script · \(percent)%"
        case "ready": "Ready to render on device"
        case "failed": "Needs attention"
        default: "Updating…"
        }
    }
    var statusIcon: String {
        switch status {
        case "running": "clock.arrow.circlepath"
        case "ready": "checkmark.circle"
        default: "exclamationmark.triangle"
        }
    }
}
