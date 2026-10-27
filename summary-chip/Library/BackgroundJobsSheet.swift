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
        Form {
            if let job {
                Section { header(job) }
                Section {
                    actions(job)
                } footer: { Text(job.guidance) }
                if let failure = job.error {
                    Section {
                        Label {
                            Text(failure.message).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    } header: { Text("Error") } footer: {
                        Text(failure.code).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if !job.logs.isEmpty {
                    Section("Activity") {
                        ForEach(Array(job.logs.enumerated()), id: \.element.id) { index, entry in
                            logRow(entry, latest: index == job.logs.count - 1, job: job)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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

    private func header(_ job: BackgroundJob) -> some View {
        VStack(spacing: 12) {
            Image(systemName: job.headerSymbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: job.status == "running")
                .frame(width: 64, height: 64)
                .background(job.statusColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 4) {
                Text(job.title).font(.title3.bold()).multilineTextAlignment(.center)
                Text(job.statusTitle).font(.subheadline.weight(.medium)).foregroundStyle(job.statusColor)
                Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if job.status == "running" {
                ProgressView(value: Double(job.percent), total: 100).tint(job.statusColor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func actions(_ job: BackgroundJob) -> some View {
        VStack(spacing: 10) {
            if job.status == "ready" {
                Button { open(render: true) } label: {
                    Label("Watch HD Video", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("background-job-render")
            }
            Button { open(render: false) } label: {
                Label("Open Podcast", systemImage: "waveform").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(.vertical, 4)
    }

    private func logRow(_ entry: BackgroundJob.Log, latest: Bool, job: BackgroundJob) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: latest ? "circle.inset.filled" : "circle.fill")
                .font(.system(size: latest ? 11 : 7))
                .foregroundStyle(latest ? AnyShapeStyle(job.statusColor) : AnyShapeStyle(.tertiary))
                .frame(width: 12)
            Text(entry.message)
                .foregroundStyle(latest ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.at, style: .time)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
        case "ready": "Ready to open"
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
    var headerSymbol: String {
        switch status {
        case "running": "arrow.triangle.2.circlepath"
        case "ready": "checkmark"
        default: "exclamationmark"
        }
    }
    var statusColor: Color {
        switch status {
        case "running": .blue
        case "ready": .green
        default: .orange
        }
    }
    var guidance: String {
        switch status {
        case "running": String(localized: "You can close this sheet or quit the app. Video work continues on the server.")
        case "ready": String(localized: "HD video renders in the cloud and downloads when ready. Choose Download in the podcast for a 4K export on this device.")
        default: String(localized: "Open the podcast and choose Generate Video or Regenerate to try again.")
        }
    }
}
